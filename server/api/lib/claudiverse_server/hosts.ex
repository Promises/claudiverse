defmodule ClaudiverseServer.Hosts do
  @moduledoc """
  Host agents: one per machine (Promises/claudiverse-host-agent), connected
  OUT to this server on the "host:<name>" channel with a per-host token. They
  are how the operator's app lists a machine's folders and starts a seat on
  it ("New seat"). A host is online while its channel is joined.

  The server ASKS, the agent ANSWERS: `request/5` pushes {request_id, op,
  args} down the host's channel and waits for its "reply". The agent is the
  authority on what it allows (roots, modes, limits); the server checks the
  request shape and who may ask before relaying.

  Spawns and resumes are asynchronous (`spawn/3`, `resume/4`): cv-spawn waits
  for the new seat's shell and checks it started, which can take tens of
  seconds — too long to hold a phone's request. The outcome is broadcast as
  "host_spawn" (with "op" spawn|resume) on the user's `events_topic/1`.
  """
  use GenServer

  import Ecto.Query

  alias ClaudiverseServer.Repo
  alias ClaudiverseServer.Hosts.Machine

  @registry ClaudiverseServer.Hosts.Registry
  @requests ClaudiverseServer.Hosts.Requests
  @spawn_interval_ms 10_000
  @spawn_timeout_ms 120_000

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, %{last_spawn: %{}, unplaced: %{}}}

  def child_specs do
    [
      Supervisor.child_spec({Registry, keys: :unique, name: @registry}, id: @registry),
      Supervisor.child_spec({Registry, keys: :unique, name: @requests}, id: @requests),
      __MODULE__
    ]
  end

  def events_topic(user_id), do: "operator:events:#{user_id}"

  # --- presence -------------------------------------------------------------

  @doc """
  Register the calling channel as host `name`'s agent. A newer connection
  replaces an older one (the older is told to stop), like SeatLinks.
  """
  def register(user_id, name, meta) do
    key = {user_id, name}

    case Registry.register(@registry, key, meta) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, old}} when old == self() ->
        Registry.update_value(@registry, key, fn _ -> meta end)
        :ok

      # The old channel stops on :host_replaced and its entry goes with it;
      # only one that does not let go within 2 s is killed.
      {:error, {:already_registered, old}} ->
        send(old, :host_replaced)
        await_release(key, old, 100)
        register(user_id, name, meta)
    end
  end

  defp await_release(key, old, 0) do
    if match?([{^old, _}], Registry.lookup(@registry, key)), do: Process.exit(old, :kill)
    Process.sleep(10)
  end

  defp await_release(key, old, n) do
    case Registry.lookup(@registry, key) do
      [{^old, _}] -> Process.sleep(20) && await_release(key, old, n - 1)
      _ -> :ok
    end
  end

  @doc """
  Note that host `name`'s agent is here now (it joined or left): the time
  goes to its machine row, and the change to the operator's apps as "host"
  %{"name", "online", "last_seen_at"} on `events_topic/1`.
  """
  def seen(user_id, name, online?) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert!(%Machine{user_id: user_id, name: name, last_seen_at: now},
      on_conflict: [set: [last_seen_at: now, updated_at: NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)]],
      conflict_target: [:user_id, :name]
    )

    Phoenix.PubSub.broadcast(ClaudiverseServer.PubSub, events_topic(user_id),
      {"host", %{"name" => name, "online" => online?, "last_seen_at" => now}})

    :ok
  end

  @doc "The machines the user's agents have joined as: %{name => last_seen_at}."
  def machines(user_id) do
    from(m in Machine, where: m.user_id == ^user_id, select: {m.name, m.last_seen_at}) |> Repo.all() |> Map.new()
  end

  @doc "Online hosts: [{name, meta}]."
  def online(user_id) do
    Registry.select(@registry, [{{{user_id, :"$1"}, :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  The machine a connection from `ip` comes from: the one online agent of the
  user's that connects from that address, or nil when none or several do. All
  machines are on one LAN and the server sees their real addresses (measured
  2026-10-07: M5 .204, M1 .180, XPS 15 .107, XPS 13 .196, not a Docker
  gateway), so a seat that never reported its host can be placed. Never a guess.
  """
  def host_at(_user_id, nil), do: nil

  def host_at(user_id, ip) do
    case for({name, %{ip: ^ip}} <- online(user_id), do: name) do
      [name] -> name
      _ -> nil
    end
  end

  @doc """
  Place seat row `session` on the machine at `ip` when its row has no host.
  With no single agent there YET, the seat is remembered and placed when an
  agent at that address registers (place_waiting/2): after a server restart
  the seats and the agents rejoin at the same moment, and a seat that came
  back first found no agent (measured 2026-10-07: 4 of 13 placed, the other 9
  rejoined before the M5's agent). Returns the session.
  """
  def place(_user_id, %{host: host} = session, _ip) when is_binary(host), do: session
  def place(_user_id, session, nil), do: session

  def place(user_id, session, ip) do
    case host_at(user_id, ip) do
      nil ->
        GenServer.cast(__MODULE__, {:unplaced, {user_id, session.id}, ip})
        session

      name ->
        ClaudiverseServer.Sessions.place_on_host(session, name)
    end
  end

  @doc "An agent at `ip` registered: place the seats that were waiting for one there."
  def place_waiting(_user_id, nil), do: :ok

  def place_waiting(user_id, ip) do
    with name when is_binary(name) <- host_at(user_id, ip) do
      for id <- GenServer.call(__MODULE__, {:take_unplaced, user_id, ip}),
          %{host: nil} = s <- [ClaudiverseServer.Sessions.get_session(id)],
          do: ClaudiverseServer.Sessions.place_on_host(s, name)
    end

    :ok
  end

  @doc "An address as a string, IPv4-mapped IPv6 as plain IPv4; nil if none."
  def peer_ip({0, 0, 0, 0, 0, 0xFFFF, ab, cd}), do: peer_ip({div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)})
  def peer_ip(addr) when is_tuple(addr), do: addr |> :inet.ntoa() |> to_string()
  def peer_ip(_), do: nil

  def lookup(user_id, name) do
    case Registry.lookup(@registry, {user_id, name}) do
      [{pid, meta}] -> {:ok, pid, meta}
      [] -> :offline
    end
  end

  # --- request / reply ----------------------------------------------------------

  @doc """
  Ask host `name` to run `op` with `args`. `{:ok, result}`, `{:error,
  code, message}` as the agent answered, or `{:error, :offline | :timeout}`.
  """
  def request(user_id, name, op, args, timeout \\ 10_000) do
    case request_reply(user_id, name, op, args, timeout) do
      {:error, code, message, _reply} -> {:error, code, message}
      other -> other
    end
  end

  @doc """
  As request/5, but a refusal keeps the agent's whole reply: `{:error, code,
  message, reply}`, where the reply may carry more than the sentence (an
  outside_roots refusal names its folder as `path`).
  """
  def request_reply(user_id, name, op, args, timeout \\ 10_000) do
    with {:ok, pid, _meta} <- lookup(user_id, name) do
      rid = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      {:ok, _} = Registry.register(@requests, rid, nil)
      send(pid, {:host_request, rid, op, args})

      result =
        receive do
          {:host_reply, ^rid, %{"ok" => true} = reply} -> {:ok, reply["result"] || %{}}
          {:host_reply, ^rid, reply} -> {:error, reply["code"] || "error", reply["error"] || "failed", reply}
        after
          timeout -> {:error, :timeout}
        end

      Registry.unregister(@requests, rid)
      result
    else
      :offline -> {:error, :offline}
    end
  end

  @doc "The agent's answer to request `rid` (from HostChannel)."
  def reply(rid, payload) do
    case Registry.lookup(@requests, rid) do
      [{pid, _}] -> send(pid, {:host_reply, rid, payload})
      [] -> :ok
    end
  end

  # --- spawn ------------------------------------------------------------------

  @doc """
  Start a seat on host `name`, asynchronously. `{:ok, spawn_id}` at once, the
  outcome later as "host_spawn" on `events_topic/1`; `{:error, :offline}` or
  `{:error, :rate_limited}` up front.

  The event also carries `"started_as"`: the row the new seat registered, or
  nil if it had not registered within `:host_adopt_timeout_ms`. That row is
  given this host, origin and folder where the seat did not report them
  (Sessions.adopt_started_seat/5), so stop, interrupt and resume can reach it.
  """
  def spawn(user_id, name, args) do
    since = since_now()

    adopt = fn result ->
      known = %{working_directory: args["path"], model: args["model"]}
      id = await_adopt(user_id, name, result["title"] || args["title"], since, known, adopt_timeout_ms())
      %{"started_as" => id}
    end

    start_seat(user_id, name, "spawn", args, %{}, adopt)
  end

  @doc """
  Start a stopped seat again on host `name`, continuing Claude Code session
  `args["session_id"]`; like `spawn/3` (same rate limit). The event also
  carries `"session_id" => cv_session_id`, the row the app resumed, and
  `"resumed_as"`: the row the running seat registered (a new one, since a
  resumed seat reports a placeholder id), or nil if it had not registered
  within `:host_adopt_timeout_ms`. That row is given the conversation id, so
  it can be resumed in turn, and the placement `spawn/3` records.
  """
  def resume(user_id, name, args, cv_session_id) do
    since = since_now()

    adopt = fn result ->
      known = %{working_directory: args["path"], conversation_id: args["session_id"]}
      id = await_adopt(user_id, name, result["title"] || args["title"], since, known, adopt_timeout_ms())
      %{"resumed_as" => id}
    end

    start_seat(user_id, name, "resume", args, %{"session_id" => cv_session_id}, adopt)
  end

  @doc """
  Start a seat from a profile (Profiles.start/2), asynchronously: the agent's
  `start_profile` op, which checks the profile against the machine's own
  rules. Like `spawn/3`, but the outcome goes to `done.(event)` (the profile
  records it) instead of a "host_spawn" broadcast; `event["started_as"]` is
  the row the seat registered, given the profile's placement.
  """
  def start_profile(user_id, name, args, known, done) do
    since = since_now()

    adopt = fn _result ->
      %{"started_as" => await_adopt(user_id, name, args["name"], since, known, adopt_timeout_ms())}
    end

    start_seat(user_id, name, "start_profile", args, %{}, adopt, done)
  end

  defp since_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.add(-1) |> NaiveDateTime.truncate(:second)

  defp await_adopt(user_id, name, title, since, known, left) do
    case ClaudiverseServer.Sessions.adopt_started_seat(user_id, name, title, since, known) do
      {:ok, session} -> session.id
      _ when left <= 0 -> nil
      _ ->
        Process.sleep(500)
        await_adopt(user_id, name, title, since, known, left - 500)
    end
  end

  defp start_seat(user_id, name, op, args, extra, on_ok, done \\ nil) do
    done = done || fn event -> Phoenix.PubSub.broadcast(ClaudiverseServer.PubSub, events_topic(user_id), {"host_spawn", event}) end

    with {:ok, _pid, _meta} <- lookup(user_id, name),
         :ok <- GenServer.call(__MODULE__, {:spawn_slot, {user_id, name}}) do
      spawn_id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

      Task.Supervisor.start_child(ClaudiverseServer.Tasks, fn ->
        event =
          case request(user_id, name, op, args, spawn_timeout_ms()) do
            {:ok, result} -> Map.merge(%{"ok" => true, "title" => result["title"], "error" => nil}, on_ok.(result))
            {:error, code, message} -> %{"ok" => false, "title" => args["title"], "error" => "#{code}: #{message}"}
            {:error, reason} -> %{"ok" => false, "title" => args["title"], "error" => to_string(reason)}
          end

        done.(Map.merge(event, Map.merge(extra, %{"spawn_id" => spawn_id, "host" => name, "op" => op})))
      end)

      {:ok, spawn_id}
    else
      :offline -> {:error, :offline}
      {:error, _} = error -> error
    end
  end

  @impl true
  def handle_cast({:unplaced, key, ip}, state), do: {:noreply, Map.update!(state, :unplaced, &Map.put(&1, key, ip))}

  @impl true
  def handle_call({:take_unplaced, user_id, ip}, _from, state) do
    {taken, kept} = Map.split_with(Map.get(state, :unplaced, %{}), fn {{u, _id}, a} -> u == user_id and a == ip end)
    {:reply, for({{_u, id}, _a} <- taken, do: id), %{state | unplaced: kept}}
  end

  def handle_call({:spawn_slot, key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    interval = spawn_interval_ms()

    case Map.get(state.last_spawn, key) do
      last when is_integer(last) and now - last < interval ->
        {:reply, {:error, :rate_limited}, state}

      _ ->
        {:reply, :ok, put_in(state.last_spawn[key], now)}
    end
  end

  defp spawn_interval_ms, do: Application.get_env(:claudiverse_server, :host_spawn_interval_ms, @spawn_interval_ms)
  defp adopt_timeout_ms, do: Application.get_env(:claudiverse_server, :host_adopt_timeout_ms, 30_000)
  defp spawn_timeout_ms, do: Application.get_env(:claudiverse_server, :host_spawn_timeout_ms, @spawn_timeout_ms)
end
