defmodule ClaudiverseServer.Repo do
  use Ecto.Repo,
    otp_app: :claudiverse_server,
    adapter: Ecto.Adapters.SQLite3
end
