defmodule Mix.Tasks.Claudiverse.Register do
  @moduledoc "Register a new user: mix claudiverse.register email password"
  @shortdoc "Register a new Claudiverse user"

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [email, password] ->
        case ClaudiverseServer.Accounts.register_user(%{email: email, password: password}) do
          {:ok, user} ->
            token = ClaudiverseServer.Accounts.create_user_api_token(user)
            Mix.shell().info("User created: #{user.email} (id: #{user.id})")
            Mix.shell().info("API token: #{token}")

          {:error, changeset} ->
            errors =
              Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
              |> Enum.map(fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)
              |> Enum.join("; ")

            Mix.shell().error("Failed: #{errors}")
        end

      _ ->
        Mix.shell().error("Usage: mix claudiverse.register <email> <password>")
    end
  end
end
