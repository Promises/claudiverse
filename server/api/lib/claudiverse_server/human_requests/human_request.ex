defmodule ClaudiverseServer.HumanRequests.HumanRequest do
  use Ecto.Schema
  import Ecto.Changeset

  schema "human_requests" do
    field :summary, :string
    field :detail, :string
    field :status, :string, default: "open"
    field :resolved_at, :utc_datetime

    belongs_to :session, ClaudiverseServer.Sessions.Session
    belongs_to :user, ClaudiverseServer.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(request, attrs) do
    request
    |> cast(attrs, [:summary, :detail, :status, :resolved_at, :session_id, :user_id])
    |> validate_required([:summary, :status, :session_id, :user_id])
    |> validate_length(:summary, min: 1, max: 500)
    |> validate_length(:detail, max: 10_000)
    |> validate_inclusion(:status, ~w(open resolved))
  end
end
