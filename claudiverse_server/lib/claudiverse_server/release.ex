defmodule ClaudiverseServer.Release do
  @moduledoc """
  Release-time tasks, callable from a built release without Mix.

  In production there is no `mix`, so `mix claudiverse.register` is unavailable.
  Use these via `bin/claudiverse_server eval`, e.g.:

      bin/claudiverse_server eval 'ClaudiverseServer.Release.create_user("a@b.c", "password")'

  Migrations are NOT run here: they run automatically at boot via
  `Ecto.Migrator` in the application supervision tree (see Application). A
  `migrate/0` helper is provided for the rare case you want to run them
  out-of-band.
  """

  @app :claudiverse_server

  @doc """
  Register a user and print a fresh API bearer token. Bearer token is what the
  `Authorization: Bearer <token>` header (and the orchestrator's CLAUDIVERSE_TOKEN)
  must carry. Tokens are DB-backed per user — there is no server-side token env var.
  """
  def create_user(email, password) do
    load_repo()

    case ClaudiverseServer.Accounts.register_user(%{email: email, password: password}) do
      {:ok, user} ->
        token = ClaudiverseServer.Accounts.create_user_api_token(user)
        IO.puts("User created: #{user.email} (id: #{user.id})")
        IO.puts("API token: #{token}")
        {:ok, token}

      {:error, changeset} ->
        IO.puts("Failed to create user: #{inspect(changeset.errors)}")
        {:error, changeset}
    end
  end

  @doc """
  Mint an "app" token for an existing user and print it — the only token that
  may force a message into a busy seat. It never expires and no login or
  logout revokes it.

      bin/claudiverse_server eval 'ClaudiverseServer.Release.create_app_token("a@b.c")'
  """
  def create_app_token(email) do
    load_repo()

    case ClaudiverseServer.Accounts.get_user_by_email(email) do
      nil ->
        IO.puts("No user #{email}")
        {:error, :no_user}

      user ->
        token = ClaudiverseServer.Accounts.create_user_api_token(user, "app")
        IO.puts("App token: #{token}")
        {:ok, token}
    end
  end

  @doc """
  Print the tokens a new machine needs (Accounts.connect_machine/2): the seat
  token for its claudiverse-seat mod and host agent, and the host token for
  its host agent. `name` is the machine's name as its host agent reports it
  (by default its hostname).

      bin/claudiverse_server eval 'ClaudiverseServer.Release.connect_machine("a@b.c", "my-laptop")'
  """
  def connect_machine(email, name) do
    load_repo()

    with user when not is_nil(user) <- ClaudiverseServer.Accounts.get_user_by_email(email),
         {:ok, %{seat_token: seat, host_token: host}} <- ClaudiverseServer.Accounts.connect_machine(user, name) do
      IO.puts("Machine: #{name}")
      IO.puts("Seat token: #{seat}")
      IO.puts("Host token: #{host}")
      {:ok, %{seat_token: seat, host_token: host}}
    else
      nil ->
        IO.puts("No user #{email}")
        {:error, :no_user}

      {:error, :bad_host_name} ->
        IO.puts("A machine name is 1-128 of A-Z a-z 0-9 . _ -")
        {:error, :bad_host_name}
    end
  end

  @doc "Run pending migrations explicitly (normally automatic at boot)."
  def migrate do
    Application.load(@app)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  # Start only what user/token creation needs (Repo + crypto) — NOT the whole
  # app, so this works alongside a running release without clashing on the HTTP
  # port. Runs in its own short-lived BEAM node via `bin/<app> eval`.
  defp load_repo do
    Application.load(@app)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:bcrypt_elixir)

    for repo <- repos() do
      {:ok, _} = repo.start_link(pool_size: 2)
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)
end
