defmodule ClaudiverseServer.AppBuilds.AppBuild do
  use Ecto.Schema
  import Ecto.Changeset

  schema "app_builds" do
    field :version_code, :integer
    field :version_name, :string
    field :commit, :string
    field :notes, :string
    field :sha256, :string
    field :size, :integer
    field :file, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(build, attrs) do
    build
    |> cast(attrs, [:version_code, :version_name, :commit, :notes, :sha256, :size, :file])
    |> validate_required([:version_code, :version_name, :sha256, :size, :file])
    |> validate_number(:version_code, greater_than: 0)
    |> validate_length(:version_name, max: 100)
    |> validate_length(:notes, max: 20_000)
  end
end
