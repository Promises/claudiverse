defmodule ClaudiverseServer.Knowledge.Build do
  @moduledoc """
  One full link+build of the whole image.

  ## Verdicts

    * `PASS`  — linked, an ELF was produced, and differing bytes did not
      regress against the last green.
    * `FAIL`  — did not link, or differing bytes went UP.
    * `ERROR` — the build could not run at all (toolchain absent, VM down).
      Distinct on purpose: a build that could not run is not a failing build,
      and collapsing them makes an infrastructure outage look like a code
      regression.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @verdicts ~w(PASS FAIL ERROR)
  def verdicts, do: @verdicts

  schema "kb_builds" do
    field :sha, :string
    field :fleet, :string, default: "lorem-fleet"
    field :region, :string, default: "usa"
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :verdict, :string
    field :raw_output, :string
    field :differing_bytes, :integer
    field :elf_bytes, :integer
    field :undefined_symbols, :integer
    field :integrations_since, :integer
    field :runner, :string
    field :environment, :string
    timestamps()
  end

  def changeset(b, attrs) do
    b
    |> cast(attrs, [
      :sha, :fleet, :region, :started_at, :finished_at, :verdict, :raw_output,
      :differing_bytes, :elf_bytes, :undefined_symbols, :integrations_since,
      :runner, :environment
    ])
    |> validate_required([:sha, :verdict, :started_at])
    |> validate_inclusion(:verdict, @verdicts)
    |> require_evidence()
    |> unique_constraint([:sha, :region])
  end

  # A PASS with no ELF size is a claim with nothing behind it. The whole point
  # of this record is to be the bisect anchor later.
  defp require_evidence(cs) do
    if get_field(cs, :verdict) == "PASS" and is_nil(get_field(cs, :elf_bytes)) do
      add_error(cs, :elf_bytes, "a PASS must record the ELF size it produced")
    else
      cs
    end
  end
end
