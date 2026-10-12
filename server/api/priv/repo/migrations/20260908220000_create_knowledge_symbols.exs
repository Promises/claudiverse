defmodule ClaudiverseServer.Repo.Migrations.CreateKnowledgeSymbols do
  use Ecto.Migration

  # Symbols — the alias layer that makes address-anchored knowledge survive a
  # rename.
  #
  # WHY THIS TABLE EXISTS. Commit bb754675 in the lorem-fleet repo renamed asm glabels
  # and desynced every reference keyed on the old spelling; the link broke and
  # stayed broken for days. Separately, func_00348DA0 and GuiMenuListSetRows had
  # to be reconciled by hand as THE SAME ADDRESS under two names. Knowledge keyed
  # on a name inherits both failures.
  #
  # So: the ADDRESS is the identity, and a name is a claim about an address that
  # was true over an interval. Renaming does not rewrite history — it closes the
  # old row's validity and opens a new one, so a document written under the old
  # name is still findable by it.
  #
  # ⚠️ DEVIATION from CLAUDIVERSE_EXPANSION.md §1, recorded deliberately: the
  # plan wrote `valid_from_revision_id` / `valid_to_revision_id` referencing
  # kb_revisions. That is wrong — a rename is an event in the CODE, not in a
  # knowledge document, so tying validity to a document revision would make the
  # symbol timeline depend on unrelated edits. Validity is a time interval, with
  # an optional source_sha naming the commit that made it true.
  def change do
    create table(:kb_symbols) do
      add :address, :string, null: false
      add :name, :string, null: false
      add :build, :string, null: false
      # NULL valid_to == currently true. Exactly one such row per (address,
      # build) is enforced by the partial unique index below.
      add :valid_from, :utc_datetime, null: false
      add :valid_to, :utc_datetime
      add :source_sha, :string
      add :recorded_by, :string, null: false

      timestamps()
    end

    create index(:kb_symbols, [:address, :build])
    # Lookup by a DEAD name must still work — that is the entire point.
    create index(:kb_symbols, [:name])

    # One current name per address per build. Partial, so historical rows
    # (valid_to NOT NULL) are unconstrained and a rename can be recorded freely.
    create unique_index(:kb_symbols, [:address, :build],
             where: "valid_to IS NULL",
             name: :kb_symbols_current_per_address_index
           )
  end
end
