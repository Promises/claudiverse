defmodule ClaudiverseServer.IncidentLog do
  @moduledoc """
  An append-only record of every 5xx this server answers, and of the exception
  behind it, that SURVIVES a container swap.

  WHY THIS EXISTS. The fix for the handoff/set 500s (1d54247, 2026-09-26) could
  not be confirmed in production: the plan was to compare "Database busy"
  counts over ~30 h against the old ~24 per 30 h, and every container swap
  starts an empty `docker logs`. Three swaps in one day erased the window — a
  restart is not evidence-neutral, it resets the instrument. This file lives on
  the /data volume beside the database, so a count spans deploys.

  ⛔ NOT IN SQLITE. The incident being counted is often SQLite itself being
  busy; recording it in a table would fail for the same reason, exactly when
  the record matters. One JSON line per incident is appended to a file instead
  (`O_APPEND`: lines under the pipe buffer size do not interleave).

  ⛔ NO REQUEST CONTENT. Method, route, status, request id and the exception's
  module and message only — never params, bodies or headers, which carry API
  and OAuth tokens.

  ⚠️ A HANDLER THAT RAISES IS DETACHED BY :telemetry, silently and for good, so
  everything here is rescued: a broken diagnostic must not switch itself off.

  Path: `INCIDENT_LOG` if set, else `incidents.jsonl` beside `DATABASE_PATH`,
  else nothing is recorded (tests set it explicitly).

  Reading it: `GET /api/incidents?since=<iso8601>` (counts by route and status
  plus the latest entries), or the file itself on the server.
  """
  require Logger

  @handler_id "claudiverse-incident-log"
  @message_cap 300

  def attach do
    :telemetry.attach_many(
      @handler_id,
      [[:phoenix, :endpoint, :stop], [:phoenix, :router_dispatch, :exception]],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def path do
    cond do
      p = Application.get_env(:claudiverse_server, :incident_log) -> p
      p = System.get_env("INCIDENT_LOG") -> p
      db = System.get_env("DATABASE_PATH") -> Path.join(Path.dirname(db), "incidents.jsonl")
      true -> nil
    end
  end

  @doc false
  def handle_event([:phoenix, :endpoint, :stop], _measurements, %{conn: conn}, _config) do
    if conn.status && conn.status >= 500 do
      record(%{
        kind: "response",
        status: conn.status,
        method: conn.method,
        route: route(conn),
        request_id: request_id(conn)
      })
    end
  rescue
    _ -> :ok
  end

  def handle_event([:phoenix, :router_dispatch, :exception], _measurements, meta, _config) do
    {mod, msg} = describe(meta[:reason])

    record(%{
      kind: "exception",
      method: meta[:conn] && meta.conn.method,
      route: meta[:route] || (meta[:conn] && route(meta.conn)),
      exception: mod,
      message: msg,
      request_id: meta[:conn] && request_id(meta.conn)
    })
  rescue
    _ -> :ok
  end

  def handle_event(_, _, _, _), do: :ok

  @doc "Append one incident. Returns :ok whatever happens."
  def record(fields) do
    case path() do
      nil ->
        :ok

      p ->
        line = Jason.encode!(Map.put(fields, :at, DateTime.utc_now() |> DateTime.truncate(:millisecond))) <> "\n"
        File.write(p, line, [:append])
        :ok
    end
  rescue
    e ->
      Logger.warning("[incident_log] could not record: #{Exception.message(e)}")
      :ok
  end

  @doc """
  Incidents since `since` (a DateTime): counts by kind/route/status/exception
  and the last `limit` entries. Reads the whole file; it is small by design —
  one line per 5xx.
  """
  def summary(since, limit \\ 20) do
    entries =
      case path() && File.read(path()) do
        {:ok, body} ->
          body
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn l ->
            case Jason.decode(l) do
              {:ok, e} -> [e]
              _ -> []
            end
          end)
          |> Enum.filter(fn e ->
            case DateTime.from_iso8601(e["at"] || "") do
              {:ok, at, _} -> DateTime.compare(at, since) != :lt
              _ -> false
            end
          end)

        _ ->
          []
      end

    counts =
      entries
      |> Enum.frequencies_by(&Map.take(&1, ["kind", "route", "status", "exception"]))
      |> Enum.map(fn {k, n} -> Map.put(k, "count", n) end)
      |> Enum.sort_by(&(-&1["count"]))

    %{since: since, total: length(entries), counts: counts, latest: Enum.take(entries, -limit)}
  end

  defp route(conn) do
    case conn.private[:phoenix_route] || conn.private[:plug_route] do
      {route, _} when is_binary(route) -> route
      route when is_binary(route) -> route
      _ -> conn.request_path |> String.split("/") |> Enum.map_join("/", &if(&1 =~ ~r/^\d+$/, do: ":id", else: &1))
    end
  end

  defp request_id(conn) do
    case Plug.Conn.get_resp_header(conn, "x-request-id") do
      [id | _] -> id
      _ -> nil
    end
  end

  defp describe(%{__exception__: true} = e),
    do: {inspect(e.__struct__), e |> Exception.message() |> String.slice(0, @message_cap)}

  defp describe(other), do: {nil, other |> inspect() |> String.slice(0, @message_cap)}
end
