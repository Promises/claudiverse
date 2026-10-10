defmodule ClaudiverseServer.SlowQueryLog do
  @moduledoc """
  Log every Repo query slower than a threshold, with the pool WAIT split out.

  WHY THIS EXISTS. On 2026-09-26 the server wedged for ten minutes: one core
  pegged, the port still listening, health probes timing out, and the log going
  silent mid-traffic. The snapshot showed a single-task `GET /api/tasks/714`
  taking 59,063 ms — a primary-key lookup plus indexed reads — and nothing that
  said whether it had been WORKING for a minute or WAITING for one of the five
  pool connections. That distinction decides the fix (a bad query vs. a starved
  pool), and without it the incident was undiagnosable.

  So each slow query logs `queue` (time waiting for a pool connection) apart
  from `query` (time SQLite spent executing). A high `queue` with a low `query`
  is starvation; a high `query` is the query itself.

  ⛔ PARAMETERS ARE NEVER LOGGED. Query params carry API tokens and OAuth
  credentials (anthropic_auths, user_tokens), and this log is read over SSH and
  shipped around during incidents. Only the SQL text's head and the source table
  are logged.

  ⚠️ A HANDLER THAT RAISES IS DETACHED BY :telemetry, silently and for good.
  Everything here is wrapped so a malformed measurement cannot switch the
  diagnostic off at the moment it is needed.

  Threshold: `SLOW_QUERY_MS` (default 500). Logged at :warning, so it survives
  the production log level, and it carries the request_id of the request that
  ran it, because the handler runs in the caller's process.
  """
  require Logger

  @event [:claudiverse_server, :repo, :query]
  @handler_id "claudiverse-slow-query-log"
  @sql_head 240

  def attach do
    threshold =
      case Integer.parse(System.get_env("SLOW_QUERY_MS") || "500") do
        {n, _} when n > 0 -> n
        _ -> 500
      end

    :telemetry.detach(@handler_id)
    :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, %{threshold_ms: threshold})
  end

  def handle_event(_event, measurements, metadata, %{threshold_ms: threshold}) do
    total = ms(measurements[:total_time])

    if total >= threshold do
      Logger.warning(
        "SLOW QUERY total=#{total}ms queue=#{ms(measurements[:queue_time])}ms " <>
          "query=#{ms(measurements[:query_time])}ms decode=#{ms(measurements[:decode_time])}ms " <>
          "source=#{inspect(metadata[:source])} sql=#{sql_head(metadata[:query])}"
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp ms(nil), do: 0
  defp ms(native) when is_integer(native), do: System.convert_time_unit(native, :native, :millisecond)
  defp ms(_), do: 0

  defp sql_head(sql) when is_binary(sql) do
    flat = sql |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(flat) > @sql_head, do: String.slice(flat, 0, @sql_head) <> "…", else: flat
  end

  defp sql_head(_), do: "?"
end
