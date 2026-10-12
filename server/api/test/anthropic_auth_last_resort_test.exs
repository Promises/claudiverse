defmodule ClaudiverseServer.AnthropicAuthLastResortTest do
  @moduledoc """
  With every account cooling, a lease still gets an account cooled ONLY by the
  usage poll's 95% margin whose limits are all under 100%.

  🔴 Operator 2026-10-03: Work sat at weekly 96% (poll margin) while Personal
  was out of its 5-hour session — and the fleet had no account at all.
  """
  # Not async: SQLite has one writer, and parallel sandbox transactions on
  # anthropic_auths timed out with "Database busy" (measured 2026-10-04).
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.AnthropicAuths
  alias ClaudiverseServer.AnthropicAuths.{AnthropicAuth, UsagePoller}

  defp in_seconds(s), do: DateTime.utc_now() |> DateTime.add(s, :second) |> DateTime.truncate(:second)

  defp limits(pairs), do: %{"limits" => for({k, p} <- pairs, do: %{"kind" => k, "percent" => p})}

  defp auth!(label, priority, attrs) do
    Repo.insert!(struct(%AnthropicAuth{label: label, priority: priority, status: "cooling_down"}, attrs))
  end

  defp personal_out_of_session!,
    do: auth!("Personal", 10, %{cooldown_until: in_seconds(600), cooldown_reason: "session at 100% >= 95% (usage poll)",
                                 usage_snapshot: limits(session: 100, weekly_all: 14)})

  test "every account cooling: the one inside its margin is leased", _ do
    personal_out_of_session!()
    work = auth!("Work", 100, %{cooldown_until: in_seconds(86_400), cooldown_reason: "weekly_all at 96% >= 95% (usage poll)",
                                usage_snapshot: limits(session: 0, weekly_all: 96)})
    assert AnthropicAuths.pick().id == work.id
  end

  test "a 429-derived cooldown is never a last resort", _ do
    personal_out_of_session!()
    auth!("Work", 100, %{cooldown_until: in_seconds(900), cooldown_reason: "rate limited (429)",
                         usage_snapshot: limits(weekly_all: 90)})
    assert AnthropicAuths.pick() == nil
  end

  test "a limit actually at 100% is never a last resort", _ do
    personal_out_of_session!()
    auth!("Work", 100, %{cooldown_until: in_seconds(86_400), cooldown_reason: "weekly_all at 100% >= 95% (usage poll)",
                         usage_snapshot: limits(weekly_all: 100)})
    assert AnthropicAuths.pick() == nil
  end

  test "an available account always wins over a last resort", _ do
    auth!("Work", 100, %{cooldown_until: in_seconds(86_400), cooldown_reason: "weekly_all at 96% >= 95% (usage poll)",
                         usage_snapshot: limits(weekly_all: 96)})
    personal = Repo.insert!(%AnthropicAuth{label: "Personal", priority: 10, status: "available"})
    assert AnthropicAuths.pick().id == personal.id
  end

  test "when an account comes back after a last-resort period, seats are told to move back" do
    # The poll found nothing leasable (seats on a last resort)...
    assert UsagePoller.maybe_announce_upgrade(%{best_id: nil}) |> Map.get(:best_id) == :none
    # ...then Personal is available again: that is an improvement to announce.
    personal = Repo.insert!(%AnthropicAuth{label: "Personal", priority: 10, status: "available"})
    assert UsagePoller.maybe_announce_upgrade(%{best_id: :none}).best_id == personal.id
  end
end
