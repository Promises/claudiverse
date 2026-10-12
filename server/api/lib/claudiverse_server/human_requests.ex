defmodule ClaudiverseServer.HumanRequests do
  @moduledoc """
  A seat asking for the operator: `cv_request_human` on the seat, a
  notification on the operator's phone, resolved when the operator opens the
  seat (the app calls `resolve_session/2`).

  - Only a seat that OPTED IN may ask: its launcher sets CLAUDIVERSE_NOTIFY=1
    and the seat reports it (sessions.can_notify). Operator decision
    2026-10-03: ipsum-admin and lorem-admin. A runner seat never may, opted in or
    not — runner workers are driven by their runner, not the operator.
  - At most ONE open request per seat: asking again updates it (new text,
    bumped time), so a seat that loops cannot spam the phone.
  - Every change is broadcast on `topic/1` for the app's
    "operator:human_requests" channel.
  """
  import Ecto.Query

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.HumanRequests.HumanRequest
  alias ClaudiverseServer.Sessions.Session

  @doc "The PubSub topic a user's operator channel listens on."
  def topic(user_id), do: "operator:human_requests:#{user_id}"

  @doc """
  Open (or refresh) the seat's request. `{:ok, request}`, `{:error, :runner}`
  for a runner seat (nothing is written), or `{:error, changeset}`.
  """
  def request(%Session{origin: "runner"}, _summary, _detail), do: {:error, :runner}
  def request(%Session{} = s, summary, detail) do
    if ClaudiverseServer.Sessions.Access.can_notify?(s), do: do_request(s, summary, detail), else: {:error, :not_allowed}
  end

  defp do_request(%Session{} = session, summary, detail) do
    result =
      case open_for_session(session.id) do
        nil ->
          %HumanRequest{}
          |> HumanRequest.changeset(%{summary: summary, detail: detail, status: "open",
                                      session_id: session.id, user_id: session.user_id})
          |> Repo.insert()

        existing ->
          # Ecto skips the write when nothing changed, which would leave the
          # time unbumped; the timestamp is set explicitly so a repeat ask is
          # always visible as recent.
          existing
          |> HumanRequest.changeset(%{summary: summary, detail: detail})
          |> Ecto.Changeset.force_change(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
          |> Repo.update()
      end

    with {:ok, req} <- result do
      broadcast(session.user_id, "human_request", serialize(req, session.title))
      {:ok, req}
    end
  end

  @doc "A user's requests with the given status, newest first, each with its seat's title."
  def list(user_id, status \\ "open") do
    from(r in HumanRequest,
      join: s in assoc(r, :session),
      where: r.user_id == ^user_id and r.status == ^status,
      order_by: [desc: r.updated_at, desc: r.id],
      select: {r, s.title}
    )
    |> Repo.all()
    |> Enum.map(fn {r, title} -> serialize(r, title) end)
  end

  @doc "Resolve every open request for a session; returns how many."
  def resolve_session(user_id, session_id) do
    open =
      from(r in HumanRequest,
        where: r.user_id == ^user_id and r.session_id == ^session_id and r.status == "open"
      )
      |> Repo.all()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for req <- open do
      {:ok, _} = req |> HumanRequest.changeset(%{status: "resolved", resolved_at: now}) |> Repo.update()
      broadcast(user_id, "human_request_resolved", %{"id" => req.id, "session_id" => req.session_id})
    end

    length(open)
  end

  def serialize(%HumanRequest{} = r, seat_title) do
    %{
      "id" => r.id,
      "session_id" => r.session_id,
      "seat_title" => seat_title,
      "summary" => r.summary,
      "detail" => r.detail,
      "status" => r.status,
      "inserted_at" => r.inserted_at,
      "updated_at" => r.updated_at
    }
  end

  defp open_for_session(session_id) do
    from(r in HumanRequest, where: r.session_id == ^session_id and r.status == "open", limit: 1)
    |> Repo.one()
  end

  defp broadcast(user_id, event, payload) do
    Phoenix.PubSub.broadcast(ClaudiverseServer.PubSub, topic(user_id), {event, payload})
  end
end
