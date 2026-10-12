defmodule ClaudiverseServerWeb.IncidentController do
  @moduledoc """
  `GET /api/incidents?since=<iso8601>` — the server's own 5xx record
  (ClaudiverseServer.IncidentLog): counts by kind, route, status and exception
  since a time, plus the latest entries. Default window: the last 24 hours.

  It exists so a fix like 1d54247 can be confirmed by any seat, across
  deploys, without SSH to the server.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.IncidentLog

  def index(conn, params) do
    since =
      with s when is_binary(s) <- params["since"],
           {:ok, dt, _} <- DateTime.from_iso8601(s) do
        dt
      else
        _ -> DateTime.add(DateTime.utc_now(), -86_400, :second)
      end

    json(conn, IncidentLog.summary(since))
  end
end
