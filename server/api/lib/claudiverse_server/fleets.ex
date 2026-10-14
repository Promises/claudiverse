defmodule ClaudiverseServer.Fleets do
  @moduledoc """
  What the operator sets per fleet (`fleet_settings`): `paused`. A paused
  fleet is left out of a bulk restart unless asked (Restarts). A fleet with
  no row is not paused.
  """
  import Ecto.Query

  alias ClaudiverseServer.Repo

  defmodule Setting do
    @moduledoc false
    use Ecto.Schema

    schema "fleet_settings" do
      field :fleet, :string
      field :paused, :boolean, default: false
      belongs_to :user, ClaudiverseServer.Accounts.User
      timestamps()
    end
  end

  @doc "The user's paused fleets, as a MapSet of names."
  def paused(user_id) do
    from(f in Setting, where: f.user_id == ^user_id and f.paused, select: f.fleet) |> Repo.all() |> MapSet.new()
  end

  @doc "Pause or resume `fleet` (a name as fleets use: A-Z a-z 0-9 . _ -)."
  def set_paused(user_id, fleet, paused?) when is_boolean(paused?) do
    if Regex.match?(~r/\A[A-Za-z0-9._-]{1,64}\z/, fleet) do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.insert!(%Setting{user_id: user_id, fleet: fleet, paused: paused?, inserted_at: now, updated_at: now},
        on_conflict: [set: [paused: paused?, updated_at: now]],
        conflict_target: [:user_id, :fleet]
      )

      :ok
    else
      {:error, :bad_fleet}
    end
  end
end
