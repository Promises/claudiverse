defmodule ClaudiverseServer.TestIsolation do
  @moduledoc """
  What one test leaves in memory must not reach the next.

  Each test's rows roll back with its sandbox, and SQLite then hands the next
  test the same ids: user 1, session 1 again. State the application keeps in
  processes does not roll back, so a later test met an earlier one's Room for
  "its" session (with a sidecar grace timer still pending), its runner slots in
  `GET /api/fleets`, its spawn slots in `Hosts`; and a background task still
  writing after its test ended held SQLite's lock ("Database busy") for the
  next. For a test that is not async, DataCase therefore:

  - before its sandbox: stops whatever an earlier test left running
    (`stop_leftovers/0`);
  - in its sandbox (shared, so their `init` reads this test's rows): restarts
    the processes that keep state per user, seat or session (`reset_state/0`);
  - when it ends, before its sandbox goes: stops what it started, after
    letting each finish what it was doing.

  Async tests run before all others and share these processes, so they are
  left alone.
  """

  alias ClaudiverseServer.{AnthropicAuths, AutoResume, Hosts, Notifications, Proxy, Schedules, Sessions}

  # Supervised children that keep state per user, seat or session. Each is
  # restarted, so it starts from its own init. (The Rooms and the proxy
  # observers are stopped instead: they are started on demand. The registries,
  # SeatLinks' among them, drop an entry when its process ends.)
  @stateful [
    Notifications.Router,
    ClaudiverseServer.QuestionHolds,
    ClaudiverseServer.SeatInbox,
    ClaudiverseServer.LoginThrottle,
    ClaudiverseServer.Setup,
    ClaudiverseServer.Runners,
    Proxy.Credentials,
    AnthropicAuths.RefreshLock,
    Schedules.Scheduler,
    AutoResume.Server,
    ClaudiverseServer.GitHub.Poller,
    Hosts
  ]

  # Started on demand, one per seat or Claude session.
  @dynamic [Proxy.Supervisor, Sessions.Supervisor]

  @doc "Stops background tasks, Rooms and proxy observers, each after what it was doing."
  def stop_leftovers do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(ClaudiverseServer.Tasks), is_pid(pid),
        do: Task.Supervisor.terminate_child(ClaudiverseServer.Tasks, pid)

    # A synchronous call returns only after every earlier message is handled:
    # stopping one in the middle of an insert would leave the sandbox a dead client.
    for sup <- @dynamic, {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
      try do
        :sys.get_state(pid, 5_000)
      catch
        :exit, _ -> :ok
      end

      DynamicSupervisor.terminate_child(sup, pid)
    end

    :ok
  end

  @doc "Restarts each stateful child, so it holds nothing from an earlier test."
  def reset_state do
    for id <- @stateful do
      :ok = Supervisor.terminate_child(ClaudiverseServer.Supervisor, id)

      case Supervisor.restart_child(ClaudiverseServer.Supervisor, id) do
        {:ok, _} -> :ok
        {:ok, _, _} -> :ok
        # A child disabled in this environment (its init returns :ignore).
        {:error, :ignore} -> :ok
      end
    end

    :ok
  end
end
