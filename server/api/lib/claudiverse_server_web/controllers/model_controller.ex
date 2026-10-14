defmodule ClaudiverseServerWeb.ModelController do
  @moduledoc "`GET /api/models`: the models a seat can run (ClaudiverseServer.Models)."
  use ClaudiverseServerWeb, :controller

  def index(conn, _params), do: json(conn, ClaudiverseServer.Models.catalog())
end
