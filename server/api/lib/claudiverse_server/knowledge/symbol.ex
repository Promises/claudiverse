defmodule ClaudiverseServer.Knowledge.Symbol do
  @moduledoc """
  A name that was true for an address over an interval.

  The address is the identity; the name is a claim about it. `valid_to == nil`
  means "currently true"; a rename closes the old row and opens a new one, so a
  document written under the old spelling remains findable by it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "kb_symbols" do
    field :address, :string
    field :name, :string
    field :build, :string
    field :valid_from, :utc_datetime
    field :valid_to, :utc_datetime
    field :source_sha, :string
    field :recorded_by, :string
    timestamps()
  end

  def changeset(sym, attrs) do
    sym
    |> cast(attrs, [:address, :name, :build, :valid_from, :valid_to, :source_sha, :recorded_by])
    |> validate_required([:address, :name, :build, :valid_from, :recorded_by])
    |> normalise_address()
    |> unique_constraint([:address, :build], name: :kb_symbols_current_per_address_index)
  end

  # Stored normalised so 0x00336B88 / 0x336b88 / 336B88 are one address, exactly
  # as anchors are — otherwise a symbol and its anchor could disagree about which
  # address they mean.
  defp normalise_address(cs) do
    case get_field(cs, :address) do
      nil -> cs
      a -> put_change(cs, :address, ClaudiverseServer.Knowledge.Anchor.normalise("address", a))
    end
  end
end
