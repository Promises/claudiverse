defmodule ClaudiverseServer.Restarts do
  @moduledoc """
  Restarting idle seats on their machine's current runtime: the host agent's
  `restart_seat` stops a seat cleanly and starts it again on the same
  conversation, with what its process was started with; a seat in a plain
  terminal comes back in tmux (adopted). See the host agent's seat control.

  ## Which seats

  Only idle ones, strictly. The server checks, then the machine re-checks
  right before the stop (`restart_plan`, then `restart_seat`):

  - running, on a machine that is online, not a runner's worker (origin
    "runner": its runner restarts it);
  - not the caller's own seat unless `include_self`;
  - the fleet filters (`fleets`, `exclude_fleets`), a paused fleet left out
    by default (`exclude_paused`), the `exclude_session_ids`;
  - a protected seat (its profile's `protected`) only when named in
    `session_ids`, or for one seat with `confirm_protected`;
  - `only_outdated`: its client version is not the version it would get;
  - its room idle, no agent working, no background task running, no
    permission prompt or AskUserQuestion open, nothing for 60 s.

  A seat that fails a check is skipped with its reason, never queued.

  ## Doing it

  One seat at a time: each waits for its new row to register (or 90 s)
  before the next. Each step is an event on `Hosts.events_topic/1`:
  "seat_restart" `{restart_id, batch_id, session_id, title, host, outcome:
  started|restarted|adopted|skipped|failed, reason, reason_code, old_version,
  new_version, new_session_id, killed, note}`, and for a bulk
  "restart_batch" `{batch_id, host, state: started|done, total, counts}`.
  """
  require Logger

  import Ecto.Query

  alias ClaudiverseServer.{Fleets, Hosts, Profiles, Repo, Sessions}
  alias ClaudiverseServer.Profiles.Profile
  alias ClaudiverseServer.Sessions.{Room, Session}

  @min_idle_s 60
  @plan_timeout_ms 15_000
  @restart_timeout_ms 120_000
  # The machine's refusals made before it stops anything.
  @before_stop ~w(busy limit runner not_found several process_changed not_allowed bad_request outside_roots)
  @version ~r/\d+\.\d+\.\d+/

  # --- the plan -----------------------------------------------------------------------

  @doc """
  The plan for `sessions` (rows with last_activity_at): one entry each, with
  its action (restart | adopt | skip) and, for a seat its machine looked at,
  `launch` (the names of what it would start with). `opts` are the request's
  filters; `single` is true for POST /sessions/:id/restart.
  """
  def plan(user_id, sessions, opts, single \\ false) do
    ctx = context(user_id, opts, single)
    # A seat its machine's agent did not start takes a new place under that
    # agent's max_seats when restarted: the seats planned after it on the same
    # machine are checked with those places taken, as the restarts will be.
    {entries, _taking} =
      Enum.map_reduce(sessions, %{}, fn s, taking ->
        e = entry(user_id, s, Map.put(ctx, :taking, Map.get(taking, s.host, 0)))
        {Map.delete(e, :takes_place), if(e[:takes_place], do: Map.update(taking, s.host, 1, &(&1 + 1)), else: taking)}
      end)

    entries
  end

  defp context(user_id, opts, single) do
    %{
      single: single,
      online: Map.new(Hosts.online(user_id)),
      paused: Fleets.paused(user_id),
      protected: from(p in Profile, where: p.user_id == ^user_id and p.protected, select: p.id) |> Repo.all() |> MapSet.new(),
      named: set(opts["session_ids"]),
      excluded: set(opts["exclude_session_ids"]) || MapSet.new(),
      fleets: list(opts["fleets"]),
      exclude_fleets: list(opts["exclude_fleets"]) || [],
      exclude_paused: opts["exclude_paused"] != false,
      only_outdated: opts["only_outdated"] == true,
      caller: int(opts["caller"]),
      include_self: opts["include_self"] == true,
      confirm_protected: opts["confirm_protected"] == true,
      now: NaiveDateTime.utc_now()
    }
  end

  defp entry(user_id, %Session{} = s, ctx) do
    base = %{
      session_id: s.id, title: s.title, host: s.host, fleet: s.fleet, origin: s.origin,
      protected: s.profile_id != nil and MapSet.member?(ctx.protected, s.profile_id),
      client_version: version(s.client_version), target_version: target_version(s, ctx), launch: nil
    }

    case server_check(s, base, ctx) do
      {code, reason} -> skip(base, code, reason)
      :ok -> machine_check(user_id, s, base, ctx)
    end
  end

  defp skip(base, code, reason), do: Map.merge(base, %{action: "skip", reason: reason, reason_code: code})

  # The checks the server can make; the machine makes its own after.
  defp server_check(s, base, ctx) do
    named? = ctx.named != nil and MapSet.member?(ctx.named, s.id)
    room = room_status(s.id)

    cond do
      s.status != :running or s.type == :proxy -> {"not_running", "#{s.title} is not running"}
      is_nil(s.host) -> {"no_machine", "#{s.title} did not report its machine"}
      not Map.has_key?(ctx.online, s.host) -> {"offline", "#{s.title}'s machine #{s.host} is offline"}
      s.origin == "runner" -> {"runner", "#{s.title} is a cv-runner's worker; its runner restarts it"}
      s.id == ctx.caller and not ctx.include_self -> {"self", "#{s.title} is the caller's own seat"}
      MapSet.member?(ctx.excluded, s.id) -> {"excluded", "#{s.title} was excluded"}
      ctx.named != nil and not named? and not ctx.single -> {"excluded", "#{s.title} was not among the seats named"}
      ctx.fleets != nil and s.fleet not in ctx.fleets -> {"fleet", "#{s.title}'s fleet is not among those asked for"}
      s.fleet != nil and s.fleet in ctx.exclude_fleets -> {"fleet", "#{s.title}'s fleet #{s.fleet} was excluded"}
      ctx.exclude_paused and s.fleet != nil and MapSet.member?(ctx.paused, s.fleet) and not named? ->
        {"paused", "#{s.title}'s fleet #{s.fleet} is paused"}
      base.protected and not named? and not (ctx.single and ctx.confirm_protected) ->
        {"protected", "#{s.title} is protected; name it, or confirm"}
      ctx.only_outdated and base.client_version != nil and base.client_version == base.target_version ->
        {"up_to_date", "#{s.title} already runs #{base.client_version}"}
      true -> idle_check(s, room, ctx.now)
    end
  end

  defp idle_check(s, room, now) do
    idle_for = if s.last_activity_at, do: NaiveDateTime.diff(now, s.last_activity_at), else: nil

    cond do
      room[:sidecar_connected] != true -> {"not_running", "#{s.title} has no live connection"}
      room[:idle] != true -> {"busy", "#{s.title} is working"}
      (room[:busy_agents] || 0) > 0 -> {"busy", "#{s.title} has #{room[:busy_agents]} agent(s) working"}
      (room[:background_running] || 0) > 0 -> {"background", "#{s.title} has #{room[:background_running]} background task(s) running"}
      Room.get_pending_permissions(s.id) != [] -> {"permission", "#{s.title} is waiting on a permission prompt"}
      open_question?(Room.get_replay_buffer(s.id)) -> {"question", "#{s.title} is waiting on a question"}
      idle_for != nil and idle_for < @min_idle_s -> {"recent_activity", "#{s.title} did something #{idle_for} s ago; it restarts after #{@min_idle_s} s idle"}
      true -> :ok
    end
  end

  # A seat with no room (nothing live) has no status: an empty one.
  defp room_status(id) do
    Room.get_status(id, 2_000)
  catch
    :exit, _ -> %{}
  end

  @doc "Whether the last AskUserQuestion in `messages` has no answer (tool_result) after it."
  def open_question?(messages) do
    Enum.reduce(messages, nil, fn m, open ->
      blocks = (is_map(m) && get_in(m, ["message", "content"])) || []
      blocks = if is_list(blocks), do: blocks, else: []

      Enum.reduce(blocks, open, fn
        %{"type" => "tool_use", "name" => "AskUserQuestion", "id" => id}, _ -> id
        %{"type" => "tool_result", "tool_use_id" => id}, open_id when id == open_id -> nil
        _, acc -> acc
      end)
    end) != nil
  end

  # What the machine says it would do (restart_plan), or why it would not.
  defp machine_check(user_id, s, base, ctx) do
    case Hosts.request(user_id, s.host, "restart_plan", Map.put(agent_args(user_id, s), "taking", ctx.taking), @plan_timeout_ms) do
      {:ok, p} ->
        Map.merge(base, %{
          action: p["action"], reason: nil, reason_code: nil, takes_place: p["takes_place"] != false,
          target_version: version(p["target_version"]) || base.target_version,
          launch: %{via: p["via"], argv: p["argv"] || [], env: p["env"] || [], carried: p["carried"] || [], dropped: p["dropped"] || []}
        })

      {:error, "bad_request", "unknown op" <> _} -> skip(base, "refused", "#{s.host}'s host agent cannot restart seats yet (it needs 0.14); update it")
      {:error, code, message} -> skip(base, refusal_code(code), message)
      {:error, :offline} -> skip(base, "offline", "#{s.title}'s machine #{s.host} is offline")
      {:error, :timeout} -> skip(base, "refused", "#{s.host} did not answer")
    end
  end

  defp refusal_code(code) when code in ["busy", "runner", "not_found", "not_restarted"], do: code
  # A restart is never paced, so its only limit is max_seats: it could not
  # start again, and the machine says so before stopping anything.
  defp refusal_code("limit"), do: "max_seats"
  defp refusal_code(_), do: "refused"

  # What the agent needs: the seat's conversation (the only way it is found),
  # its title, fleet and mode, and for a profile's seat its start_profile args.
  # The mode is the one its room last heard (from the seat, or the agent
  # reading its footer), or none: the row's column is only the mode it was
  # registered with, "default" when nothing said, and the agent then takes the
  # one its process was started with.
  defp agent_args(user_id, s) do
    profile =
      with id when is_integer(id) <- s.profile_id, %Profile{} = p <- Profiles.get(user_id, id) do
        Profiles.launch_args(user_id, p)
      else
        _ -> nil
      end

    %{"session_id" => s.claude_session_id, "conversation_id" => s.conversation_id, "title" => s.title,
      "fleet" => s.fleet, "mode" => (room_status(s.id) || %{})[:permission_mode], "profile" => profile}
  end

  defp target_version(s, ctx) do
    meta = ctx.online[s.host] || %{}
    spawn = meta[:spawn] || %{}
    version(spawn[:version])
  end

  defp version(nil), do: nil
  defp version(v) when is_binary(v), do: with([m] <- Regex.run(@version, v), do: m, else: (_ -> nil))
  defp version(_), do: nil

  # --- doing it ---------------------------------------------------------------------------

  @doc "Restart one planned seat (its entry from `plan/4`) in the background; returns its restart_id."
  def start_one(user_id, entry) do
    id = new_id()
    Task.Supervisor.start_child(ClaudiverseServer.Tasks, fn -> run_one(user_id, entry, id, nil) end)
    id
  end

  @doc "Restart the planned seats one at a time in the background; returns the batch_id."
  def start_batch(user_id, entries, host) do
    batch = new_id()

    Task.Supervisor.start_child(ClaudiverseServer.Tasks, fn ->
      todo = Enum.reject(entries, &(&1.action == "skip"))
      announce(user_id, "restart_batch", %{batch_id: batch, host: host, state: "started", total: length(entries), counts: counts([])})

      for e <- entries, e.action == "skip" do
        announce(user_id, "seat_restart", event(e, new_id(), batch, %{outcome: "skipped"}))
      end

      outcomes = Enum.map(todo, &run_one(user_id, &1, new_id(), batch))
      skipped = for e <- entries, e.action == "skip", do: "skipped"
      announce(user_id, "restart_batch", %{batch_id: batch, host: host, state: "done", total: length(entries), counts: counts(outcomes ++ skipped)})
    end)

    batch
  end

  defp run_one(user_id, entry, id, batch) do
    s = Sessions.get_session(entry.session_id)
    announce(user_id, "seat_restart", event(entry, id, batch, %{outcome: "started"}))
    since = NaiveDateTime.utc_now() |> NaiveDateTime.add(-1)

    {outcome, extra} =
      case Hosts.request(user_id, entry.host, "restart_seat", agent_args(user_id, s), @restart_timeout_ms) do
        {:ok, result} ->
          row = await_row(user_id, s, entry.host, since, register_ms())
          if row && row.id != s.id, do: Room.ended_by_machine(s.id)
          new_version = row && version(row.client_version)
          wanted = version(result["target_version"]) || entry.target_version

          note =
            [result["note"],
             if(new_version && wanted && new_version != wanted, do: "it registered with #{new_version}, not #{wanted}")]
            |> Enum.reject(&is_nil/1)
            |> Enum.join("; ")

          done = %{new_version: new_version, new_session_id: row && row.id, killed: result["killed"] == true, note: if(note == "", do: nil, else: note)}

          cond do
            # Stopped and started, but not seen to come back: not a success.
            row == nil ->
              {"failed", Map.merge(done, %{reason: "it was started again, but its new row had not registered after #{div(register_ms(), 1000)} s", reason_code: "not_registered"})}

            result["action"] == "adopt" -> {"adopted", done}
            true -> {"restarted", done}
          end

        {:error, "not_restarted", message} ->
          # Stopped and not started again (the machine tried twice): its row
          # ends now, so no app shows a dead seat as running.
          Room.ended_by_machine(s.id)
          {"failed", %{reason: message, reason_code: "not_restarted"}}

        # Refused before the stop (it went busy, or could not start again):
        # nothing was stopped.
        {:error, code, message} when code in @before_stop -> {"skipped", %{reason: message, reason_code: refusal_code(code)}}
        {:error, code, message} -> {"failed", %{reason: message, reason_code: refusal_code(code)}}
        {:error, reason} -> {"failed", %{reason: "#{entry.host}: #{reason}", reason_code: to_string(reason)}}
      end

    announce(user_id, "seat_restart", event(entry, id, batch, Map.put(extra, :outcome, outcome)))
    Logger.info("[restarts] #{entry.title} on #{entry.host}: #{outcome}#{if extra[:reason], do: " (#{extra[:reason]})"}")
    outcome
  end

  # The row the restarted seat registered: a mod seat re-registers on its own
  # row (the same conversation), another seat on a new one.
  defp register_ms, do: Application.get_env(:claudiverse_server, :restart_register_ms, 90_000)

  defp await_row(user_id, s, host, since, left) do
    known = %{working_directory: s.working_directory, origin: s.origin}

    case Sessions.adopt_started_seat(user_id, host, s.title, since, known) do
      {:ok, row} -> row
      _ when left <= 0 -> nil
      _ ->
        Process.sleep(1_000)
        await_row(user_id, s, host, since, left - 1_000)
    end
  end

  defp event(entry, id, batch, extra) do
    Map.merge(
      %{restart_id: id, batch_id: batch, session_id: entry.session_id, title: entry.title, host: entry.host,
        reason: entry.reason, reason_code: entry.reason_code, old_version: entry.client_version, new_version: nil,
        new_session_id: nil, killed: false, note: nil},
      extra
    )
  end

  defp counts(outcomes) do
    Map.merge(%{"restarted" => 0, "adopted" => 0, "skipped" => 0, "failed" => 0}, Enum.frequencies(outcomes))
  end

  defp announce(user_id, event, payload),
    do: Phoenix.PubSub.broadcast(ClaudiverseServer.PubSub, Hosts.events_topic(user_id), {event, payload})

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp set(l) when is_list(l), do: l |> Enum.map(&int/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
  defp set(_), do: nil
  defp list(l) when is_list(l), do: Enum.filter(l, &is_binary/1)
  defp list(_), do: nil
  defp int(n) when is_integer(n), do: n
  defp int(s) when is_binary(s), do: with({n, ""} <- Integer.parse(s), do: n, else: (_ -> nil))
  defp int(_), do: nil
end
