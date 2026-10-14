defmodule ClaudiverseServer.AnthropicAuths.UsageDaily do
  @moduledoc """
  Once a day, a minute after local midnight (UsageHistory.default_tz/0): the
  day that ended goes to the server log as one line, and the usage history
  is thinned (UsageHistory.thin/1).

      [usage] 2026-10-12 (Europe/Oslo) weekly use: Personal +18% (10% → 28%), Work +9% (25% → 34%, reset 09:00)

  Missed while the server was down: that day's line is not written later
  (GET /api/anthropic_auths/usage_history has every day).
  """
  use GenServer

  require Logger

  alias ClaudiverseServer.AnthropicAuths.UsageHistory

  def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:run, state) do
    tz = UsageHistory.default_tz()
    yesterday = Date.add(UsageHistory.local_date(DateTime.utc_now(), tz), -1)

    try do
      Logger.info(UsageHistory.daily_line(yesterday, tz))
      deleted = UsageHistory.thin()
      if deleted > 0, do: Logger.info("[usage] thinned the history: #{deleted} samples removed")
    rescue
      e -> Logger.warning("[usage] the daily line or thinning failed: #{Exception.message(e)}")
    end

    schedule()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule do
    now = DateTime.utc_now()
    Process.send_after(self(), :run, DateTime.diff(UsageHistory.next_run(now, UsageHistory.default_tz()), now, :millisecond))
  end
end
