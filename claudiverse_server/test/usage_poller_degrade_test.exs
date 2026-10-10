defmodule ClaudiverseServer.UsagePollerDegradeTest do
  @moduledoc """
  When the account seats are on stops being leasable (the poll cooled it at its
  margin), the poller moves seats off it at once instead of leaving each to its
  own 429. MEASURED 2026-10-06 01:08Z: Personal cooled at 96% and no seat moved.
  """
  # Not async: SQLite has one writer (see anthropic_auth_last_resort_test).
  use ClaudiverseServer.DataCase, async: false

  import ExUnit.CaptureLog
  require Logger

  alias ClaudiverseServer.AnthropicAuths.{AnthropicAuth, UsagePoller}
  alias ClaudiverseServer.Proxy.Credentials

  defp in_seconds(s), do: DateTime.utc_now() |> DateTime.add(s, :second) |> DateTime.truncate(:second)

  setup do
    # The announcement is an info line; the test config logs above info.
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
    personal = Repo.insert!(%AnthropicAuth{label: "Personal", priority: 10, status: "available"})
    work = Repo.insert!(%AnthropicAuth{label: "Work", priority: 100, status: "available"})
    %{personal: personal, work: work}
  end

  defp cool!(auth),
    do: auth |> Ecto.Changeset.change(status: "cooling_down", cooldown_until: in_seconds(3600), cooldown_reason: "session at 96% >= 95% (usage poll)") |> Repo.update!()

  test "the best account cooling moves seats, and drops the proxy's cached lease", ctx do
    cool!(ctx.personal)
    :sys.replace_state(Credentials, fn st -> %{st | lease: %{auth_id: ctx.personal.id, label: "Personal"}, leased_at: System.monotonic_time(:millisecond)} end)

    log = capture_log(fn -> assert UsagePoller.maybe_announce_upgrade(%{best_id: ctx.personal.id}).best_id == ctx.work.id end)
    assert log =~ "best account now Work"
    assert log =~ "moving seats"
    assert :sys.get_state(Credentials).lease == nil
  end

  test "no change, no announcement (control)", ctx do
    log = capture_log(fn -> assert UsagePoller.maybe_announce_upgrade(%{best_id: ctx.personal.id}).best_id == ctx.personal.id end)
    refute log =~ "moving seats"
  end

  test "boot records the best without announcing", ctx do
    log = capture_log(fn -> assert UsagePoller.maybe_announce_upgrade(%{best_id: nil}).best_id == ctx.personal.id end)
    refute log =~ "moving seats"
    refute log =~ "notifying seats"
  end
end
