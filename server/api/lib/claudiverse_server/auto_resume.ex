defmodule ClaudiverseServer.AutoResume do
  @moduledoc """
  Auto-resume: a seat whose turn died on a proxy or connection error gets one
  `continue` once the server can serve it again, instead of sitting idle until
  someone types it.

  Two causes, both seen by the API proxy (ClaudiverseServerWeb.ProxyPlug):

  - **The pool was empty.** A pooled model call was refused with
    `no_available_auth`. The seat is nudged once an account is leasable again
    (`AnthropicAuths.pick/0` finds one): a weekly reset, an upgrade, a cooldown
    that ran out.
  - **A server restart cut the stream.** A response was still streaming to the
    seat when the server went down. Every row still `in_flight` at boot is such
    a seat; it is nudged once the grace period after boot has passed, so the
    seat's own retries and its reconnection come first.

  The nudge goes through the seat's normal reject-busy delivery
  (`Room.send_message/2`), so it never lands mid-turn: a busy seat gets it when
  it goes idle, an absent one when it is next seen. Only a running row with
  the same title and the same Claude session gets it: a fresh conversation
  under that title has no dead turn to continue.

  One nudge per seat per incident. An incident opens with the failure and
  closes when one of the seat's model calls is answered (a stream starts).
  A pool incident is opened again by an account's weekly reset; a restart
  incident only exists at boot. So a `continue` that fails again is never
  followed by another until the pool really changed, and nothing can loop.

  Every function here runs in `AutoResume.Server`, one process, so a tick, a
  seat going idle and the proxy's reports never race each other.
  """
  import Ecto.Query
  require Logger

  alias ClaudiverseServer.{AnthropicAuths, Repo, Sessions}
  alias ClaudiverseServer.AutoResume.Stall
  alias ClaudiverseServer.Sessions.Room

  @text "continue"
  @grace_s 60

  @doc "What a nudged seat receives, as a user prompt."
  def text, do: @text

  @doc "Seconds after boot before a seat whose stream the restart cut is nudged."
  def grace_s, do: Application.get_env(:claudiverse_server, __MODULE__, [])[:grace_s] || @grace_s

  @doc "The incidents that are open (`stalled` or `nudged`)."
  def open do
    Repo.all(from s in Stall, where: s.state != "clear")
  end

  def get(user_id, title), do: Repo.get_by(Stall, user_id: user_id, seat_title: title)

  # --- What the proxy saw --------------------------------------------------------

  @doc """
  A model response started streaming to the seat: it is in flight, and an
  open incident is over (the seat got an answer). `:resumed` when one was.
  """
  def stream_started({user_id, title, claude_session_id}) do
    stall = get(user_id, title) || %Stall{user_id: user_id, seat_title: title}
    resumed = stall.state != "clear"

    if resumed,
      do: Logger.info("[auto_resume] #{title} is answered again (#{stall.reason}, #{stall.state}); incident closed")

    stall
    |> Ecto.Changeset.change(
      in_flight: true,
      claude_session_id: claude_session_id || stall.claude_session_id,
      state: "clear",
      reason: nil,
      detail: nil,
      waiting: nil,
      stalled_at: nil
    )
    |> Repo.insert_or_update!()

    if resumed, do: :resumed, else: :ok
  end

  @doc "The seat's last streaming response ended (answered, interrupted or failed)."
  def stream_ended({user_id, title, _claude_session_id}) do
    from(s in Stall, where: s.user_id == ^user_id and s.seat_title == ^title and s.in_flight)
    |> Repo.update_all(set: [in_flight: false])

    :ok
  end

  @doc """
  The proxy refused the seat's model call: the pool had no account to lease.
  Opens a pool incident, unless one is already open (the seat retries, and
  each retry is refused the same way).
  """
  def refused({user_id, title, claude_session_id}, detail, now) do
    stall = get(user_id, title) || %Stall{user_id: user_id, seat_title: title}

    if stall.state != "clear" and stall.reason == "no_available_auth" do
      :already_open
    else
      Logger.info("[auto_resume] #{title}: model call refused (#{detail}); it gets a continue when an account is leasable")

      stall
      |> Ecto.Changeset.change(
        claude_session_id: claude_session_id || stall.claude_session_id,
        state: "stalled",
        reason: "no_available_auth",
        detail: detail,
        stalled_at: DateTime.truncate(now, :second),
        waiting: "pool",
        nudged_at: nil,
        nudged_session_id: nil
      )
      |> Repo.insert_or_update!()

      :opened
    end
  end

  # --- Boot and the pool ---------------------------------------------------------

  @doc """
  At boot: every seat still in flight had its stream cut by the restart. Each
  becomes a restart incident, nudged after the grace period. Returns them.
  """
  def boot(now) do
    now = DateTime.truncate(now, :second)

    for stall <- Repo.all(from s in Stall, where: s.in_flight) do
      Logger.info("[auto_resume] #{stall.seat_title}: its stream was cut by the restart; a continue follows in #{grace_s()} s")

      stall
      |> Ecto.Changeset.change(
        in_flight: false,
        state: "stalled",
        reason: "server_restart",
        detail: "a server restart cut the response mid-stream",
        stalled_at: now,
        waiting: "grace",
        nudged_at: nil,
        nudged_session_id: nil
      )
      |> Repo.update!()
    end
  end

  @doc """
  An account's weekly limit reset: a pool incident already nudged gets one more
  `continue` when its seat's last call still failed. New capacity, at most
  once a week per account, so this cannot loop.
  """
  def rearm_pool do
    {n, _} =
      from(s in Stall, where: s.state == "nudged" and s.reason == "no_available_auth")
      |> Repo.update_all(set: [state: "stalled", waiting: "pool", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])

    if n > 0, do: Logger.info("[auto_resume] weekly reset: #{n} seat(s) still refused get one more continue")
    n
  end

  # --- Nudging --------------------------------------------------------------------

  @doc """
  Nudge every stalled seat whose cause is over: the grace after a restart has
  passed, or the pool has an account to lease. Returns the stalls as left.
  """
  def nudge_due(now) do
    stalled = Repo.all(from s in Stall, where: s.state == "stalled", order_by: s.id)
    leasable = if Enum.any?(stalled, &(&1.reason == "no_available_auth")), do: leasable?(), else: false
    Enum.map(stalled, &consider(&1, now, leasable))
  end

  @doc """
  The seat `title` was seen alive as `session_id`, or went idle there: nudge
  it now if it is stalled and its cause is over.
  """
  def nudge_seat(user_id, title, now) do
    case get(user_id, title) do
      %Stall{state: "stalled"} = stall ->
        consider(stall, now, stall.reason == "no_available_auth" and leasable?())

      _ ->
        nil
    end
  end

  defp leasable?, do: AnthropicAuths.pick() != nil

  defp consider(%Stall{} = stall, now, leasable) do
    cond do
      stall.reason == "server_restart" and DateTime.diff(now, stall.stalled_at) < grace_s() -> waiting(stall, "grace")
      stall.reason == "no_available_auth" and not leasable -> waiting(stall, "pool")
      true -> attempt(stall, now)
    end
  end

  defp attempt(stall, now) do
    case target(stall) do
      nil ->
        waiting(stall, "seat")

      seat ->
        case Room.send_message(seat.id, @text) do
          :delivered ->
            Logger.info("[auto_resume] #{stall.seat_title}: sent continue to session #{seat.id} (#{stall.reason})")

            Sessions.record_event(%{
              session_id: seat.id,
              kind: "auto_resume",
              trigger: stall.reason,
              detail: %{"text" => @text, "stalled_at" => stall.stalled_at && DateTime.to_iso8601(stall.stalled_at), "detail" => stall.detail}
            })

            stall
            |> Ecto.Changeset.change(state: "nudged", waiting: nil, nudged_at: DateTime.truncate(now, :second), nudged_session_id: seat.id)
            |> Repo.update!()

          {:busy, _hint} ->
            waiting(stall, "busy")

          {:error, _} ->
            waiting(stall, "seat")
        end
    end
  end

  defp waiting(%Stall{waiting: w} = stall, w), do: stall
  defp waiting(stall, w), do: stall |> Ecto.Changeset.change(waiting: w) |> Repo.update!()

  # The seat's live row: running, not a proxy-only row, and the same Claude
  # session when the stall knows it.
  defp target(%Stall{user_id: user_id, seat_title: title, claude_session_id: sid}) do
    user_id
    |> Sessions.list_sessions_by_title(title, status: :running, limit: 5)
    |> Enum.find(&(&1.type != :proxy and (sid == nil or &1.claude_session_id == sid)))
  end
end
