defmodule ClaudiverseServerWeb.HealthController do
  @moduledoc """
  Liveness/readiness probe. Unauthenticated, dependency-light.

  Returns 200 with `{"status":"ok"}` once the app (and therefore the DB pool,
  since migrations run at boot) is up. Used by the container HEALTHCHECK and as
  a smoke-test target for deployments.
  """
  use ClaudiverseServerWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
