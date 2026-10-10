defmodule ClaudiverseServer.Adopt do
  @moduledoc """
  Adopt: put a seat someone started by hand under a profile, so the apps can
  stop, start and restart it like any profile seat.

  The seat's machine agent (0.9.0+) finds its process from Claude Code's own
  session records and, on adopt, stops exactly that process (`release_seat`);
  the profile is then started the ordinary way (Profiles.start/2), resuming the
  same conversation in a tmux session the agent runs.

  - `preview/2` says what adopting would do: the process, a profile that
    already has the seat's name, suggested profile fields, or why it cannot.
  - `adopt/3` creates the profile (or edits the existing stopped one), stops
    the process and starts the profile. A refusal anywhere before the stop
    leaves the process untouched.

  A patched seat's row can carry a STALE conversation id (ipsum-admin's row said
  6d9b917b…, its process d7dba841…), so the agent may match it by tmux session
  name and folder instead, and the resume id always comes from the PROCESS.
  """
  import Ecto.Query

  alias ClaudiverseServer.{Hosts, Profiles, Repo}
  alias ClaudiverseServer.Profiles.Profile
  alias ClaudiverseServer.Sessions.{Access, Room}

  @agent_version "0.9.0"
  @fields ~w(machine folder fleet role can_notify runtime model effort permission_mode mcp pooled autostart resume debug)

  @doc """
  The preview the app's Adopt sheet shows, for seat row `session`. A row
  with no host (older plain seats) may be looked for on `host_hint`, the
  machine the app runs on; see with_host/2.
  """
  def preview(user_id, session, host_hint \\ nil) do
    {session, guessed} = with_host(session, host_hint)
    existing = existing_profile(user_id, session.title)

    with :ok <- adoptable(user_id, session, existing),
         runtime = suggested_runtime(session),
         {:ok, found} <- locate(user_id, session, existing_runtime(existing) || runtime),
         :ok <- found_by_conversation(found, session, guessed) do
      blocked =
        if found["transcript"] == false,
          do: "runtime #{existing_runtime(existing) || runtime} cannot resume this conversation: it is not in that runtime's config dir on #{session.host}"

      %{process: process(found), existing_profile: listed(user_id, existing),
        suggested: suggested(session, found, runtime), blocked: blocked}
    else
      {:blocked, reason, :outside_roots, folder} -> blocked(user_id, existing, reason) |> Map.put(:folder, folder)
      {:blocked, reason, _code} -> blocked(user_id, existing, reason)
      {:blocked, reason} -> blocked(user_id, existing, reason)
    end
  end

  defp blocked(user_id, existing, reason) do
    %{process: nil, existing_profile: listed(user_id, existing), suggested: nil, blocked: reason}
  end

  @doc """
  Adopt `session` with the profile fields the operator confirmed. `params`
  carries the fields plus `pid`, `proc_start`, optionally `profile_id` (adopt
  into that existing profile) and `force` (stop it even mid-turn).
  `{:ok, profile}`, `{:error, code, message}` or `{:error, changeset}`.
  """
  def adopt(user_id, session, params) do
    {session, guessed} = with_host(session, params["host"])
    existing = existing_profile(user_id, session.title)

    with :ok <- adoptable(user_id, session, existing) |> as_conflict(),
         :ok <- same_profile(existing, params["profile_id"]),
         :ok <- confirm_guess(user_id, session, guessed) |> as_conflict(),
         {:ok, profile} <- save_profile(user_id, session, existing, Map.take(params, @fields)),
         :ok <- release(user_id, session, profile, params) do
      # The hand-started row ends here; the profile's seat registers its own.
      if session.status == :running, do: Room.ended_by_machine(session.id)
      Profiles.start(user_id, profile)
      {:ok, Profiles.get(user_id, profile.id)}
    end
  end

  # --- a row with no host -------------------------------------------------------

  # A row that recorded its machine is never moved to another one: the hint
  # only stands in for a host the row does not have. `guessed` says so.
  defp with_host(%{host: nil} = session, hint) when is_binary(hint) and hint != "", do: {%{session | host: hint}, true}
  defp with_host(session, _hint), do: {session, false}

  # On a machine we only guessed, a match by tmux session name and folder is
  # too weak to stop a process on: only the conversation id will do.
  defp found_by_conversation(_found, _session, false), do: :ok
  defp found_by_conversation(%{"matched_by" => "session_id"}, _session, true), do: :ok

  defp found_by_conversation(_found, session, true),
    do: {:blocked, "found only by tmux name on #{session.host}, not by conversation; its machine isn't recorded"}

  defp confirm_guess(_user_id, _session, false), do: :ok

  defp confirm_guess(user_id, session, true) do
    with {:ok, found} <- locate(user_id, session, nil), do: found_by_conversation(found, session, true)
  end

  # --- checks -------------------------------------------------------------------

  defp adoptable(user_id, session, existing) do
    cond do
      session.status != :running -> {:blocked, "it is not running; make a profile and press Start instead"}
      session.origin == "runner" -> {:blocked, "it is a cv-runner worker; its runner stops and starts it", :runner}
      # The profile id, not the origin: a fork of a profile seat (Claude Code's
      # own background fork, 2026-10-07) carries origin "profile" with no
      # profile, and is just what Adopt is for.
      session.profile_id != nil -> {:blocked, "it already runs from a profile"}
      is_nil(session.host) -> {:blocked, "its machine is not known"}
      existing && existing.machine != session.host -> {:blocked, "a profile named #{session.title} exists on #{existing.machine}, not on #{session.host}"}
      existing && profile_status(user_id, existing) in ["running", "starting"] ->
        {:blocked, "its profile #{existing.name} is already running", :profile_running}
      true -> agent_ok(user_id, session.host)
    end
  end

  defp profile_status(user_id, %Profile{} = p), do: hd(Profiles.with_status(user_id, [p])).status

  defp agent_ok(user_id, host) do
    case Hosts.lookup(user_id, host) do
      :offline -> {:blocked, "the agent on #{host} is offline"}
      {:ok, _pid, %{version: v}} when is_binary(v) ->
        if Version.compare(normal(v), @agent_version) == :lt,
          do: {:blocked, "the agent on #{host} is #{v}; adopting needs #{@agent_version}"},
          else: :ok
      {:ok, _pid, _} -> {:blocked, "the agent on #{host} is too old to adopt seats (needs #{@agent_version})"}
    end
  end

  defp normal(v) do
    case Version.parse(v) do
      {:ok, _} -> v
      :error -> "0.0.0"
    end
  end

  defp as_conflict({:blocked, reason, code, _folder}), do: {:error, to_string(code), reason}
  defp as_conflict({:blocked, reason, code}), do: {:error, to_string(code), reason}
  defp as_conflict({:blocked, reason}), do: {:error, "blocked", reason}
  defp as_conflict(:ok), do: :ok

  defp same_profile(nil, nil), do: :ok
  defp same_profile(nil, _id), do: {:error, "blocked", "there is no profile with the seat's name to adopt into"}
  defp same_profile(%Profile{}, nil), do: {:error, "blocked", "a profile with the seat's name exists; adopt into it (profile_id)"}

  defp same_profile(%Profile{id: id}, given) do
    if to_string(given) == to_string(id), do: :ok, else: {:error, "blocked", "profile #{given} is not the one named after this seat"}
  end

  # --- the agent ----------------------------------------------------------------

  defp session_ids(session), do: Enum.reject([session.conversation_id, session.claude_session_id], &is_nil/1)

  defp locate(user_id, session, runtime) do
    args = %{"session_ids" => session_ids(session), "title" => session.title, "cwd" => session.working_directory, "runtime" => runtime}

    case Hosts.request_reply(user_id, session.host, "locate_seat", args, 15_000) do
      {:ok, found} -> {:ok, found}
      # The folder an outside_roots refusal names, so the app can offer to allow it.
      {:error, "outside_roots", message, %{"path" => folder}} when is_binary(folder) -> {:blocked, message, :outside_roots, folder}
      {:error, _code, message, _reply} -> {:blocked, message}
      {:error, :offline} -> {:blocked, "the agent on #{session.host} is offline"}
      {:error, :timeout} -> {:blocked, "the agent on #{session.host} did not answer"}
    end
  end

  defp release(user_id, session, %Profile{} = p, params) do
    args = %{
      "pid" => params["pid"], "proc_start" => params["proc_start"], "force" => params["force"] == true,
      "session_ids" => Enum.uniq([p.resume | session_ids(session)]),
      "title" => session.title, "cwd" => p.folder, "runtime" => p.runtime
    }

    case Hosts.request(user_id, session.host, "release_seat", args, 30_000) do
      {:ok, _} -> :ok
      {:error, code, message} -> {:error, code, message}
      {:error, :offline} -> {:error, "offline", "the agent on #{session.host} is offline"}
      {:error, :timeout} -> {:error, "offline", "the agent on #{session.host} did not answer"}
    end
  end

  # --- the profile --------------------------------------------------------------

  defp existing_profile(user_id, title) do
    from(p in Profile, where: p.user_id == ^user_id and p.name == ^title) |> Repo.one()
  end

  defp existing_runtime(nil), do: nil
  defp existing_runtime(%Profile{runtime: r}), do: r

  defp listed(_user_id, nil), do: nil
  defp listed(user_id, %Profile{} = p), do: hd(Profiles.with_status(user_id, [p]))

  defp save_profile(user_id, session, nil, fields),
    do: Profiles.create(user_id, Map.merge(fields, %{"name" => session.title, "machine" => session.host}))

  defp save_profile(user_id, _session, %Profile{} = p, fields) do
    changed = Enum.reject(fields, fn {k, v} -> Map.get(p, String.to_existing_atom(k)) == v end) |> Map.new()

    if changed == %{} do
      {:ok, p}
    else
      case Profiles.update(user_id, p, p.revision, Map.delete(changed, "machine")) do
        {:error, :stale} -> {:error, "blocked", "the profile was edited meanwhile; look again"}
        other -> other
      end
    end
  end

  # --- what the sheet shows -------------------------------------------------------

  defp process(found) do
    Map.take(found, ~w(pid proc_start tmux status version matched_by session_id))
  end

  # The runtime the seat runs now: the mod's seats say so in their version.
  defp suggested_runtime(%{client_version: v}) when is_binary(v) do
    cond do
      String.contains?(v, "[claudiverse-mod]") -> "stock+mod"
      String.contains?(v, "[claudiverse]") -> "patched"
      true -> "stock+mod"
    end
  end

  defp suggested_runtime(_), do: "stock+mod"

  defp suggested(session, found, runtime) do
    %{
      "machine" => session.host,
      "folder" => found["cwd"] || session.working_directory,
      "fleet" => session.fleet,
      "role" => "member",
      "can_notify" => Access.can_notify?(session),
      "runtime" => runtime,
      "model" => nil,
      "effort" => nil,
      "permission_mode" => session.permission_mode || "default",
      "mcp" => ["claudiverse"],
      # Pooled by default (the preferred account, with failover). Not for a
      # patched seat: that binary leases from the same pool itself, and it has
      # never run through the pool proxy.
      "pooled" => runtime != "patched",
      "autostart" => false,
      "resume" => found["session_id"],
      "debug" => false
    }
  end
end
