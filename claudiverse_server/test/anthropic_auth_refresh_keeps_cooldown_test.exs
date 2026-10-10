defmodule ClaudiverseServer.AnthropicAuthRefreshKeepsCooldownTest do
  @moduledoc """
  Refreshing an account's TOKEN must not touch its COOLDOWN.

  🔴 MEASURED 2026-09-20 ~20:45. Personal was weekly_all 100%, cooling until its
  weekly reset. Its hourly OAuth refresh went through token_attrs/2, which wrote
  `cooldown_until: nil` — and the usage poller, seeing a leasable priority-10
  account, broadcast "preferred account available". Every seat moved INTO the
  exhausted account:

      ⚠ Moved to preferred Anthropic account 'Personal' (was auth 4)
      ⚠ Switched to Anthropic account 'Work'
      429 … retrying (1/5) … (5/5) … letting upstream handle it

  and the operator got the weekly-limit dialog on a fleet with a healthy
  fallback sitting at weekly 10%.

  The same defect also defeated the existing re-enrolment guard: token_attrs
  was merged AFTER cooldown_attrs, so the guard computed the right answer and
  then had it overwritten.
  """
  # Not async: SQLite has one writer, and parallel sandbox transactions on
  # anthropic_auths timed out with "Database busy" (measured 2026-10-04).
  use ClaudiverseServer.DataCase, async: false

  alias ClaudiverseServer.AnthropicAuths
  alias ClaudiverseServer.AnthropicAuths.AnthropicAuth

  defp in_seconds(s), do: DateTime.utc_now() |> DateTime.add(s, :second) |> DateTime.truncate(:second)

  defp same_instant(a, b), do: DateTime.compare(a, b) == :eq

  @tokens %{"access_token" => "fresh-access", "refresh_token" => "fresh-refresh", "expires_in" => 3600}

  test "a token refresh keeps an active cooldown and its reason" do
    until = in_seconds(6 * 3600)

    auth =
      Repo.insert!(%AnthropicAuth{
        label: "Personal", priority: 10, status: "cooling_down",
        cooldown_until: until, cooldown_reason: "weekly_all at 100% >= 95% (usage poll)"
      })

    assert {:ok, _} = AnthropicAuths.apply_refresh(auth, @tokens)
    after_refresh = Repo.get!(AnthropicAuth, auth.id)

    assert same_instant(after_refresh.cooldown_until, until),
           "the refresh replaced credentials AND erased a measured cooldown"
    assert after_refresh.cooldown_reason == "weekly_all at 100% >= 95% (usage poll)"
    assert after_refresh.status == "cooling_down"
    refute AnthropicAuth.leasable?(after_refresh)
  end

  test "a token refresh on an EXPIRED cooldown reports available" do
    auth =
      Repo.insert!(%AnthropicAuth{
        label: "Personal", priority: 10, status: "cooling_down",
        cooldown_until: in_seconds(-60), cooldown_reason: "old"
      })

    assert {:ok, _} = AnthropicAuths.apply_refresh(auth, @tokens)
    assert Repo.get!(AnthropicAuth, auth.id).status == "available"
  end

  test "a token refresh brings a needs_reauth account back to available" do
    auth = Repo.insert!(%AnthropicAuth{label: "Personal", priority: 10, status: "needs_reauth", cooldown_reason: "refresh rejected"})
    assert {:ok, _} = AnthropicAuths.apply_refresh(auth, @tokens)
    assert Repo.get!(AnthropicAuth, auth.id).status == "available"
  end

  test "the poller does not announce an account whose refresh just happened while cooling" do
    until = in_seconds(6 * 3600)
    personal = Repo.insert!(%AnthropicAuth{label: "Personal", priority: 10, status: "cooling_down", cooldown_until: until, cooldown_reason: "weekly"})
    work = Repo.insert!(%AnthropicAuth{label: "Work", priority: 100, status: "available"})

    {:ok, _} = AnthropicAuths.apply_refresh(personal, @tokens)

    state = ClaudiverseServer.AnthropicAuths.UsagePoller.maybe_announce_upgrade(%{best_id: work.id})
    assert state.best_id == work.id, "Personal must not have become the best leasable account"
  end
end
