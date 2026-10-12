defmodule ClaudiverseServer.Knowledge.Anchor do
  @moduledoc """
  What a document is ABOUT.

  ⭐ Addresses are the stable key; NAMES ARE ALIASES. A document keyed on the
  name `func_00336B88` rots the instant the function is renamed — which is
  exactly how commit `bb754675` desynced knowledge from code and broke the lorem-fleet
  master link, and why `func_00348DA0` and `GuiMenuListSetRows` had to be
  reconciled by hand as the same address under two spellings.

  `normalised` exists so `0x336b88`, `0x00336B88` and `00336b88` are ONE anchor
  rather than three.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(address symbol unit segment build sha tool channel fleet)
  def types, do: @types

  schema "kb_anchors" do
    field :type, :string
    field :value, :string
    field :normalised, :string
    timestamps()
  end

  def changeset(anchor, attrs) do
    anchor
    |> cast(attrs, [:type, :value])
    |> validate_required([:type, :value])
    |> validate_inclusion(:type, @types)
    |> put_normalised()
    |> unique_constraint([:type, :normalised], name: :kb_anchors_type_normalised_index)
  end

  defp put_normalised(cs) do
    case {get_field(cs, :type), get_field(cs, :value)} do
      {nil, _} -> cs
      {_, nil} -> cs
      {type, value} -> put_change(cs, :normalised, normalise(type, value))
    end
  end

  @doc """
  Canonical form. Addresses collapse to 8 lower-case hex digits so every
  spelling of the same address is one anchor; everything else is trimmed and
  down-cased.
  """
  def normalise("address", value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("0x", "")
    |> String.pad_leading(8, "0")
  end

  def normalise(_type, value), do: value |> String.trim() |> String.downcase()
end
