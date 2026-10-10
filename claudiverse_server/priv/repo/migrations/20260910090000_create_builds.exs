defmodule ClaudiverseServer.Repo.Migrations.CreateBuilds do
  @moduledoc """
  Component D — the periodic full link+build.

  ⭐ This is what makes unattended integration safe. A per-unit gate can only
  see its unit, and a whole-image link costs ~15 minutes (measured), so it
  cannot run per submission. Instead integration goes automatic on the cheap
  gate and a full build runs periodically — and when it goes red, the culprit is
  BOUNDED to the integrations since the last green.

  Operator, on why this exists: "if it fails we know it failed in the time
  between the last one and the current one, and then we can analyse the changes
  at a deeper level."
  """
  use Ecto.Migration

  def change do
    create table(:kb_builds) do
      add :sha, :string, null: false
      add :fleet, :string, null: false, default: "lorem-fleet"
      add :region, :string, null: false, default: "usa"

      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      add :verdict, :string, null: false

      # ⛔ RAW OUTPUT, not a boolean. A full build's failure mode is a wall of
      # linker errors whose FIRST TWENTY LINES are what build.sh prints to the
      # console — reading that truncated view once already produced a confident
      # wrong count of 5 where the real number was 15.
      add :raw_output, :text

      # The two numbers that make a green build comparable to the last one.
      # Byte-exactness is not the bar yet, so a REGRESSION in differing bytes is
      # the signal, not the absolute value.
      add :differing_bytes, :integer
      add :elf_bytes, :integer
      add :undefined_symbols, :integer

      # The blast radius: how many integrations landed since the previous build.
      # When this build is red and the previous was green, the culprit is in
      # exactly that set.
      add :integrations_since, :integer

      add :runner, :string
      add :environment, :string
      timestamps()
    end

    create index(:kb_builds, [:fleet, :region, :verdict, :started_at])
    create unique_index(:kb_builds, [:sha, :region])
  end
end
