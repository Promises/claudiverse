defmodule ClaudiverseServer.Profiles do
  @moduledoc """
  Seat profiles (docs/design/seat-profiles.md): one record per managed,
  long-lived seat. The profile's machine's host agent starts the seat from it
  (`start/2`, the agent's `start_profile` op); the seat registers with the
  profile id and revision, and the server fills its fleet, notify and origin
  from the profile (`registration_attrs/2`).

  Status is derived, never stored (`with_status/2`): running | starting |
  unregistered (started on its machine, never registered) | offline | failed |
  stopped, from a running seat row
  carrying the profile id, the machine's presence, and `last_start` — the
  outcome of the last start, a fact recorded beside the profile:
  `%{"at", "requested_at", "outcome" => starting|started|refused|failed|offline,
  "reason", "seat"}` — `at` when the outcome was recorded, `requested_at`
  when the start was asked for (so a client can show how long it took).

  Every change is pushed as "profile" on the user's `Hosts.events_topic/1`:
  `%{"op" => created|updated|deleted|start|stopped, "profile" => as listed}`.
  """
  import Ecto.Query
  require Logger

  alias ClaudiverseServer.{Hosts, Repo}
  alias ClaudiverseServer.Profiles.Profile
  alias ClaudiverseServer.Sessions.Session

  # The agent's refusals of the profile itself, as against a seat that failed.
  @refusals ~w(outside_roots not_allowed bad_request not_found limit)
  # A start older than this that never reported back (the server restarted
  # mid-start) no longer counts as starting.
  @starting_ms 180_000

  def list(user_id) do
    from(p in Profile, where: p.user_id == ^user_id, order_by: [asc: p.name]) |> Repo.all()
  end

  def get(user_id, id) do
    case Integer.parse(to_string(id)) do
      {n, ""} -> Repo.get_by(Profile, id: n, user_id: user_id)
      _ -> nil
    end
  end

  def create(user_id, attrs) do
    %Profile{}
    |> Profile.create_changeset(Map.put(stringify(attrs), "user_id", user_id))
    |> Repo.insert()
    |> tap_ok(&changed(user_id, "created", &1))
  end

  @doc """
  Edit `profile`, which the caller read at `revision`. `{:error, :stale}`
  when it has been edited since; the revision is bumped on success. The name
  is not editable (it is the seat's title and tmux session).
  """
  def update(user_id, %Profile{} = profile, revision, attrs) do
    cs =
      %{profile | revision: revision}
      |> Profile.update_changeset(stringify(attrs))
      |> Ecto.Changeset.optimistic_lock(:revision)

    case Repo.update(cs, stale_error_field: :revision) do
      {:ok, p} ->
        changed(user_id, "updated", p)
        {:ok, p}

      {:error, %{errors: errors} = cs} ->
        if Keyword.has_key?(errors, :revision), do: {:error, :stale}, else: {:error, cs}
    end
  end

  @doc "Delete `profile`; `{:error, :running}` while a seat runs from it."
  def delete(user_id, %Profile{} = profile) do
    if running_seat(user_id, profile.id) do
      {:error, :running}
    else
      {:ok, p} = Repo.delete(profile)
      Phoenix.PubSub.broadcast(ClaudiverseServer.PubSub, Hosts.events_topic(user_id),
        {"profile", %{"op" => "deleted", "profile" => %{id: p.id, name: p.name}}})
      {:ok, p}
    end
  end

  # --- status -----------------------------------------------------------------

  @doc """
  Each profile with its derived `status` and `seat` (the running row's id):
  running | starting | offline (its machine's agent is not connected) |
  failed (the last start was refused or the seat did not survive) | stopped.
  A running seat started from an older revision has `restart_needed`.
  """
  def with_status(user_id, profiles) do
    ids = Enum.map(profiles, & &1.id)
    online = user_id |> Hosts.online() |> Map.new()

    seats =
      from(s in Session,
        where: s.user_id == ^user_id and s.profile_id in ^ids and s.status == :running and s.type != :proxy,
        order_by: [asc: s.inserted_at, asc: s.id],
        select: {s.profile_id, %{id: s.id, revision: s.profile_revision}}
      )
      |> Repo.all()
      # The newest running row wins.
      |> Map.new()

    Enum.map(profiles, fn p ->
      seat = seats[p.id]

      status =
        cond do
          seat -> "running"
          starting?(p.last_start) -> "starting"
          unregistered?(p.last_start) -> "unregistered"
          not Map.has_key?(online, p.machine) -> "offline"
          (p.last_start || %{})["outcome"] in ["refused", "failed"] -> "failed"
          true -> "stopped"
        end

      Map.merge(serialize(p), %{
        status: status,
        seat: seat && seat.id,
        restart_needed: not is_nil(seat) and seat.revision != p.revision
      })
    end)
  end

  defp starting?(%{"outcome" => "starting", "at" => at}) do
    case DateTime.from_iso8601(at) do
      {:ok, t, _} -> DateTime.diff(DateTime.utc_now(), t, :millisecond) < @starting_ms
      _ -> false
    end
  end

  defp starting?(_), do: false

  # The machine started the seat but it never registered (it sits at a prompt
  # in its tmux session, or its mod did not load): it still runs there, so a
  # client must offer Stop. MEASURED 2026-10-05: profile-test waited at the
  # trust dialog while the app read "stopped" and offered only Start. Cleared
  # by a stop (stopped_at), or by the seat registering (then "running").
  defp unregistered?(%{"outcome" => "started", "seat" => nil} = last), do: is_nil(last["stopped_at"])
  defp unregistered?(_), do: false

  defp running_seat(user_id, profile_id) do
    from(s in Session,
      where: s.user_id == ^user_id and s.profile_id == ^profile_id and s.status == :running and s.type != :proxy,
      select: s.id,
      limit: 1
    )
    |> Repo.one()
  end

  def serialize(%Profile{} = p) do
    Map.take(p, [:id, :name, :revision, :last_start, :inserted_at, :updated_at | Profile.editable_fields()])
  end

  # --- registration -------------------------------------------------------------

  @doc """
  What a seat registering with `profile_id` is, by its profile: origin
  "profile", the profile's fleet and notify. The profile wins over what the
  seat reported; a profile id that is not the user's is dropped.
  """
  def registration_attrs(user_id, %{profile_id: id} = attrs) when is_integer(id) do
    case Repo.get_by(Profile, id: id, user_id: user_id) do
      nil -> Map.drop(attrs, [:profile_id, :profile_revision])
      p -> Map.merge(attrs, %{origin: "profile", fleet: p.fleet, can_notify: p.can_notify})
    end
  end

  def registration_attrs(_user_id, attrs), do: attrs

  # --- start / stop -------------------------------------------------------------

  @doc """
  Start `profile`'s seat on its machine, asynchronously. `:ok` at once, with
  `last_start` set to "starting"; the outcome replaces it and is pushed as a
  "profile" event. `{:error, :running | :offline | :rate_limited}` up front.
  """
  def start(user_id, %Profile{} = p, opts \\ []) do
    if running_seat(user_id, p.id) do
      {:error, :running}
    else
      args = launch_args(user_id, p)
      # A rename restarts the seat on the conversation it had, whatever the
      # profile's resume setting; "latest" lets the agent start fresh if that
      # conversation is gone from the machine.
      args = if opts[:resume], do: Map.merge(args, %{"resume" => opts[:resume], "resume_policy" => "latest"}), else: args

      known = %{origin: "profile", working_directory: p.folder, profile_id: p.id,
                profile_revision: p.revision, tmux_session: p.name, model: p.model, conversation_id: args["resume"]}

      record_start(user_id, p.id, %{"outcome" => "starting"})

      case Hosts.start_profile(user_id, p.machine, args, known, &finish_start(user_id, p.id, &1)) do
        {:ok, _} ->
          :ok

        {:error, reason} = error ->
          record_start(user_id, p.id, %{"outcome" => if(reason == :offline, do: "offline", else: "refused"),
                                          "reason" => to_string(reason)})
          error
      end
    end
  end

  @doc """
  `machine`'s agent came online: start its autostart profiles that are not
  running. Agents reconnect often (network blips, server swaps), so this
  must be a no-op when everything already runs:
  - a profile whose seat runs (or is starting) is left alone;
  - one whose last start was refused or failed within @retry_after_ms is
    skipped, so a broken profile is not restarted on every reconnect;
  - starts are spaced by the machine's start interval (Hosts' rate limit).

  `live` is what the agent reported at its join: the tmux sessions on the
  machine with a Claude Code process in them (nil from an older agent). A
  profile whose rows, all on this machine, read running while it has no live
  seat there is a leftover of a reboot or a dead process: its rows end, and it
  starts. MEASURED 2026-10-11: after an unexpected reboot of a machine, every
  profile's row still read "running", so its agent's autostart skipped them all.

  Returns the names it started.
  """
  def autostart(user_id, machine, live \\ nil) do
    profiles =
      from(p in Profile, where: p.user_id == ^user_id and p.machine == ^machine and p.autostart == true, order_by: [asc: p.name])
      |> Repo.all()

    if is_list(live), do: end_leftovers(user_id, machine, profiles, live)

    due =
      profiles
      |> Enum.zip(with_status(user_id, profiles))
      |> Enum.filter(fn {p, listed} -> listed.status in ["stopped", "failed"] and not failed_recently?(p.last_start) end)
      |> Enum.map(&elem(&1, 0))

    gap = Application.get_env(:claudiverse_server, :host_spawn_interval_ms, 10_000) + 500

    due
    |> Enum.with_index()
    |> Enum.flat_map(fn {p, i} ->
      if i > 0, do: Process.sleep(gap)

      case start(user_id, p) do
        :ok -> [p.name]
        _ -> []
      end
    end)
  end

  defp end_leftovers(user_id, machine, profiles, live) do
    for {p, %{status: "running"}} <- Enum.zip(profiles, with_status(user_id, profiles)), p.name not in live do
      hosts =
        from(s in Session,
          where: s.user_id == ^user_id and s.profile_id == ^p.id and s.status == :running and s.type != :proxy,
          select: s.host
        )
        |> Repo.all()

      if Enum.all?(hosts, &(&1 == machine)) do
        Logger.info("[profiles] #{p.name}: its row reads running but no seat lives on #{machine}; ending it so autostart starts it")
        ended(user_id, p)
      end
    end
  end

  @retry_after_ms 600_000

  defp failed_recently?(%{"outcome" => outcome, "at" => at}) when outcome in ["refused", "failed"] do
    case DateTime.from_iso8601(at) do
      {:ok, t, _} -> DateTime.diff(DateTime.utc_now(), t, :millisecond) < @retry_after_ms
      _ -> false
    end
  end

  defp failed_recently?(_), do: false

  @doc """
  Stop `profile`'s seat: its machine closes the tmux session named after it,
  and the seat's rows end at once (Room.ended_by_machine/1).
  """
  def stop(user_id, %Profile{} = p) do
    case Hosts.request(user_id, p.machine, "stop", %{"title" => p.name}) do
      {:ok, _} ->
        ended(user_id, p)
        :ok

      other ->
        other
    end
  end

  defp ended(user_id, %Profile{} = p) do
    if is_map(p.last_start) do
      stopped = Map.put(p.last_start, "stopped_at", DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601())
      from(x in Profile, where: x.id == ^p.id) |> Repo.update_all(set: [last_start: stopped])
    end

    from(s in Session,
      where: s.user_id == ^user_id and s.profile_id == ^p.id and s.status == :running and s.type != :proxy,
      select: s.id
    )
    |> Repo.all()
    |> Enum.each(&ClaudiverseServer.Sessions.Room.ended_by_machine/1)

    changed(user_id, "stopped", get(user_id, p.id) || p)
  end

  @doc "Stop (if running) and start again, so the seat picks up the current revision."
  def restart(user_id, %Profile{} = p) do
    case stop(user_id, p) do
      :ok ->
        start(user_id, p)

      # Not running on its machine: a row still marked running is stale.
      {:error, "not_found", _} ->
        ended(user_id, p)
        start(user_id, p)

      error ->
        error
    end
  end

  @doc """
  Rename `profile`, which the caller read at `revision`, to `name`.

  A seat holds its title in processes that read it once at launch (the mod's
  inbox poll and hook URLs, cv-mcp's SELF, the tmux session), so a running
  seat is stopped, renamed and started again on the conversation it had
  (`{:ok, profile, moved, :restarted}`; the start's outcome arrives as usual).
  A live rename would leave one of them writing under the old name.

  What is keyed by the title moves with it, in one transaction: the profile's
  session rows, its forum subscriptions, its handoff and the handoff's
  history, and the open forum tasks it owns; then its Router listener and
  every watch list naming it (Router.rename/2). `moved` counts each.
  Authorship (posts, documents), done tasks and task events stay as written.
  Nothing aliases the old name: a cv_send to it finds no seat.

  Refused, before anything is touched:
  `{:error, :stale}`, `{:error, %Changeset{}}` (format, or a profile has the
  name), `{:error, :name_taken, why}` (a running seat or an earlier seat's
  handoff has it), `{:error, :claimed_task, ids}` (a runner tracks those by
  title), `{:error, :busy}` (mid-turn), and the stop's own errors.
  """
  def rename(user_id, %Profile{} = p, revision, name) do
    seat = running_row(user_id, p.id)

    with :ok <- rename_checks(user_id, p, revision, name, seat),
         {:ok, resume} <- stop_for_rename(user_id, p, seat) do
      case move_name(p, name) do
        {:ok, renamed, moved} ->
          moved = Map.merge(moved, ClaudiverseServer.Notifications.Router.rename(p.name, name))
          changed(user_id, "renamed", renamed)

          if seat do
            start(user_id, renamed, resume: resume)
            {:ok, get(user_id, p.id), moved, :restarted}
          else
            {:ok, renamed, moved, :stopped}
          end

        # Lost a race after the stop: start the seat again under its old name.
        error ->
          if seat, do: start(user_id, p, resume: resume)
          error
      end
    end
  end

  defp running_row(user_id, profile_id) do
    from(s in Session,
      where: s.user_id == ^user_id and s.profile_id == ^profile_id and s.status == :running and s.type != :proxy,
      order_by: [desc: s.inserted_at, desc: s.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp rename_checks(user_id, p, revision, name, seat) do
    cs = Profile.rename_changeset(p, name)

    cond do
      revision != p.revision ->
        {:error, :stale}

      not cs.valid? ->
        {:error, cs}

      Repo.exists?(from x in Profile, where: x.user_id == ^user_id and x.name == ^name and x.id != ^p.id) ->
        {:error, Ecto.Changeset.add_error(cs, :name, "a profile with this name exists")}

      Repo.exists?(from s in Session, where: s.user_id == ^user_id and s.title == ^name and s.status == :running and s.type != :proxy) ->
        {:error, :name_taken, "a running seat is called #{name}"}

      Repo.exists?(from h in ClaudiverseServer.Forum.Handoff, where: h.role == ^name) ->
        {:error, :name_taken, "an earlier seat called #{name} left a handoff"}

      (ids = claimed_tasks(p.name)) != [] ->
        {:error, :claimed_task, ids}

      seat && busy?(seat.id) ->
        {:error, :busy}

      true ->
        :ok
    end
  end

  defp claimed_tasks(title) do
    from(t in ClaudiverseServer.Tasks.Task, where: t.claimed_by == ^title and t.state in ["CLAIMED", "RUNNING"], select: t.id)
    |> Repo.all()
  end

  # Busy only on news of a turn: a Room that is not up, or has not heard from
  # the seat yet, knows of none.
  defp busy?(session_id) do
    match?(%{idle: false, readiness_known: true}, ClaudiverseServer.Sessions.Room.get_status(session_id, 2_000))
  catch
    :exit, _ -> false
  end

  defp stop_for_rename(_user_id, _p, nil), do: {:ok, nil}

  defp stop_for_rename(user_id, p, seat) do
    resume = seat.conversation_id || seat.claude_session_id

    case stop(user_id, p) do
      :ok -> {:ok, resume}
      # Not running on its machine: its row is stale.
      {:error, "not_found", _} ->
        ended(user_id, p)
        {:ok, resume}

      error -> error
    end
  end

  defp move_name(%Profile{name: old} = p, new) do
    alias ClaudiverseServer.Forum.{Handoff, Post, Subscription}

    Repo.transaction(fn ->
      renamed =
        case p |> Profile.rename_changeset(new) |> Ecto.Changeset.change(revision: p.revision + 1) |> Repo.update() do
          {:ok, renamed} -> renamed
          {:error, cs} -> Repo.rollback(cs)
        end

      # display_title is Claude Code's own auto-title, and the apps show it in
      # place of the title. Only a patched runtime reports it, so on a mod
      # seat it is a leftover that would hide the new name: standalone-carol,
      # renamed, still showed "Runi95s commits iOS and Android impact".
      {sessions, _} = from(s in Session, where: s.profile_id == ^p.id) |> Repo.update_all(set: [title: new, display_title: nil])
      from(s in Session, where: s.profile_id == ^p.id and s.tmux_session == ^old) |> Repo.update_all(set: [tmux_session: new])

      # A subscription the new name already holds is kept once.
      held = from(s in Subscription, where: s.subscriber_title == ^new)
      from(s in Subscription, where: s.subscriber_title == ^old and s.channel_id in subquery(held |> where([h], is_nil(h.post_id)) |> select([h], h.channel_id)) and is_nil(s.post_id))
      |> Repo.delete_all()
      from(s in Subscription, where: s.subscriber_title == ^old and s.post_id in subquery(held |> where([h], not is_nil(h.post_id)) |> select([h], h.post_id)))
      |> Repo.delete_all()
      {subscriptions, _} = from(s in Subscription, where: s.subscriber_title == ^old) |> Repo.update_all(set: [subscriber_title: new])

      {handoff, _} = from(h in Handoff, where: h.role == ^old) |> Repo.update_all(set: [role: new])
      {handoff_versions, _} = from(h in Handoff.Version, where: h.role == ^old) |> Repo.update_all(set: [role: new])

      {tasks, _} =
        from(x in Post, where: x.owner == ^old and coalesce(x.status, "") != "done")
        |> Repo.update_all(set: [owner: new])

      # Named for people: the app shows the non-zero ones ("1 handoffs").
      {renamed, %{past_seats: sessions, forum_subscriptions: subscriptions, handoffs: handoff,
                  handoff_versions: handoff_versions, open_tasks: tasks}}
    end)
    |> case do
      {:ok, {renamed, moved}} -> {:ok, renamed, moved}
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
      {:error, other} -> {:error, other}
    end
  end

  @doc """
  What the agent is told. The agent maps `runtime` and `mcp` to its own
  binaries and catalog; nothing here is a path to run or a command line.
  `resume` is resolved here (the server tracks conversations): "latest" is
  the newest conversation a seat of this profile had, nil means a new one.
  `resume_policy` "latest" lets the agent start fresh when that conversation
  is not on its machine (the profile moved); "fixed" (a chosen id) must exist.
  """
  def launch_args(user_id, %Profile{} = p) do
    %{
      "name" => p.name,
      "profile_id" => p.id,
      "revision" => p.revision,
      "folder" => p.folder,
      "fleet" => p.fleet,
      "can_notify" => p.can_notify,
      "runtime" => p.runtime,
      "model" => p.model,
      "effort" => p.effort,
      "mode" => p.permission_mode,
      "mcp" => p.mcp,
      "debug" => p.debug,
      "pooled" => p.pooled,
      "resume" => resume_id(user_id, p),
      "resume_policy" => if(p.resume == "latest", do: "latest", else: "fixed")
    }
  end

  defp resume_id(_user_id, %Profile{resume: "new"}), do: nil

  defp resume_id(user_id, %Profile{resume: "latest", id: id}) do
    from(s in Session,
      where: s.user_id == ^user_id and s.profile_id == ^id and s.type != :proxy and
               (not is_nil(s.conversation_id) or not is_nil(s.claude_session_id)),
      order_by: [desc: s.inserted_at, desc: s.id],
      select: coalesce(s.conversation_id, s.claude_session_id),
      limit: 1
    )
    |> Repo.one()
  end

  defp resume_id(_user_id, %Profile{resume: id}), do: id

  defp finish_start(user_id, id, event) do
    outcome =
      cond do
        event["ok"] -> %{"outcome" => "started", "seat" => event["started_as"],
                          "reason" => if(is_nil(event["started_as"]), do: "the seat did not register within 30 s")}
        refusal?(event["error"]) -> %{"outcome" => "refused", "reason" => event["error"]}
        String.starts_with?(to_string(event["error"]), "offline") -> %{"outcome" => "offline", "reason" => event["error"]}
        true -> %{"outcome" => "failed", "reason" => event["error"]}
      end

    record_start(user_id, id, outcome)
  end

  defp refusal?(error) when is_binary(error), do: Enum.any?(@refusals, &String.starts_with?(error, &1 <> ":"))
  defp refusal?(_), do: false

  # last_start is a fact beside the profile, not an edit: no revision bump.
  # A start's outcome keeps the time it was asked for.
  defp record_start(user_id, id, outcome) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    requested_at =
      case {outcome["outcome"], get(user_id, id)} do
        {"starting", _} -> now
        {_, %Profile{last_start: %{"outcome" => "starting", "requested_at" => t}}} -> t
        _ -> now
      end

    last = Map.merge(%{"at" => now, "requested_at" => requested_at, "reason" => nil, "seat" => nil}, outcome)

    from(p in Profile, where: p.id == ^id and p.user_id == ^user_id) |> Repo.update_all(set: [last_start: last])

    case get(user_id, id) do
      nil -> :ok
      p -> changed(user_id, "start", p)
    end
  end

  # --- helpers ------------------------------------------------------------------

  defp changed(user_id, op, %Profile{} = p) do
    [listed] = with_status(user_id, [p])
    Phoenix.PubSub.broadcast(ClaudiverseServer.PubSub, Hosts.events_topic(user_id), {"profile", %{"op" => op, "profile" => listed}})
  end

  defp tap_ok({:ok, v} = ok, f), do: (f.(v); ok)
  defp tap_ok(other, _f), do: other

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
end
