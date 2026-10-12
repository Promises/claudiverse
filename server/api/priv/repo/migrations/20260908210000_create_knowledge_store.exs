defmodule ClaudiverseServer.Repo.Migrations.CreateKnowledgeStore do
  use Ecto.Migration

  # The knowledge store — durable, versioned, addressable documents.
  #
  # WHY THIS EXISTS SEPARATELY FROM THE FORUM. Today's ledger has no schema:
  # cv_fact_add takes a `channel` argument, so facts are forum_posts rows with
  # structure by convention. Three consequences, all observed:
  #   * facts inherit the forum's ~1,499-char read truncation, which is
  #     TAIL-BIASED, so `bound` and `derived_under` -- written last -- are the
  #     first fields lost;
  #   * a fact has no identity apart from a post id, so ledger citations pin
  #     post ids and (via ruling #18893) block branch reclamation;
  #   * nothing can be queried over fails_when_status, and the staleness sweep
  #     cannot exist at all, because `command` is prose inside a body rather
  #     than a column.
  #
  # A forum post is a MOMENT; a document is a CURRENT BEST STATEMENT. Posts are
  # read chronologically and bounded; knowledge is read by ANCHOR. The ~1,499
  # cap is a reasonable feed affordance and is deliberately left in place for
  # the forum -- it is only destructive when a document lives in the feed.
  #
  # Strictly additive: no existing table is altered. Running fleets are
  # unaffected until they restart and pick up the new tools.
  def change do
    # --- documents + revisions -------------------------------------------
    # kind ∈ FACT | RULING | NOTE | TOPIC | PROCEDURE   (never STATUS: status
    # is DERIVED. docs/STATUS.md:33 claims "100%-C for USA" while 65.8% of
    # .text has zero C -- it went stale precisely because it was written down.)
    #
    # scope ∈ fleet | project:<name> | <fleet-name>. Today's ledger mixes both:
    # #15883 (Ghidra is a shared server with two clients) is operational, while
    # #21786 (ordering surface byte-identical) is project. One field decides
    # the home and prevents a second migration later.
    create table(:kb_documents) do
      add :kind, :string, null: false
      add :scope, :string, null: false
      add :title, :string, null: false
      add :slug, :string, null: false
      add :created_by, :string, null: false
      add :current_revision_id, :integer
      add :archived_at, :utc_datetime

      timestamps()
    end

    create unique_index(:kb_documents, [:slug])
    create index(:kb_documents, [:kind, :scope])
    create index(:kb_documents, [:scope])

    # APPEND-ONLY. History and diff come from this chain, the way git derives
    # them from commits. A FACT is immutable: the context rejects new revisions
    # of one, because a fact is corrected by RELATION (NARROWS/RETRACTS/
    # SUPERSEDES), never by edit. Prefer NARROWS -- the usual outcome is that a
    # claim was right and smaller than stated, and a retract/keep binary
    # destroys that.
    create table(:kb_revisions) do
      add :document_id, references(:kb_documents, on_delete: :delete_all), null: false
      add :body_md, :text, null: false
      # front_matter holds the kind-specific schema. FACT requires claim,
      # command, fails_when, fails_when_status, bound, derived_under. The hot
      # fields are promoted to real columns below so they can be queried and
      # indexed -- leaving them in JSON is what makes a staleness sweep
      # impossible today.
      add :front_matter, :map, null: false, default: %{}
      add :author, :string, null: false
      add :parent_revision_id, :integer

      timestamps()
    end

    create index(:kb_revisions, [:document_id, :inserted_at])

    # Promoted FACT fields. Nullable because only FACT documents carry them.
    #
    # fails_when_status ∈ DEMONSTRATED | ASSERTED. ASSERTED means nobody has
    # SEEN the check fail, so the sweep must never report it green -- it is
    # reported as untested, permanently, until a failing arm is demonstrated.
    # A check with no reachable negative is decoration.
    alter table(:kb_revisions) do
      add :fact_command, :text
      add :fact_fails_when, :text
      add :fact_fails_when_status, :string
    end

    create index(:kb_revisions, [:fact_fails_when_status])

    # --- anchors: what a document is ABOUT --------------------------------
    # type ∈ address | symbol | unit | segment | build | sha | tool | channel | fleet
    #
    # ⭐ ANCHOR ON ADDRESS; NAMES ARE ALIASES. A document keyed on the name
    # func_00336B88 rots the instant the function is renamed -- which is exactly
    # how bb754675 desynced knowledge from code and broke master's link, and why
    # func_00348DA0 and GuiMenuListSetRows had to be reconciled by hand as the
    # same address under two spellings.
    create table(:kb_anchors) do
      add :type, :string, null: false
      add :value, :string, null: false
      # normalised: addresses lower-cased and zero-padded so 0x336b88,
      # 0x00336B88 and 00336b88 are ONE anchor rather than three.
      add :normalised, :string, null: false

      timestamps()
    end

    create unique_index(:kb_anchors, [:type, :normalised])
    create index(:kb_anchors, [:normalised])

    create table(:kb_doc_anchors) do
      add :document_id, references(:kb_documents, on_delete: :delete_all), null: false
      add :anchor_id, references(:kb_anchors, on_delete: :delete_all), null: false
      add :relation, :string, null: false, default: "about"

      timestamps()
    end

    create unique_index(:kb_doc_anchors, [:document_id, :anchor_id, :relation])
    create index(:kb_doc_anchors, [:anchor_id])

    # --- relations: corrections and citations -----------------------------
    # kind ∈ NARROWS | RETRACTS | SUPERSEDES | CITES | ANSWERS
    #
    # The context guarantees a read NEVER returns a claim without its
    # corrections -- cv_fact_get has that property today and it must survive
    # the migration. You cannot be handed a claim whose retraction exists but
    # is not shown.
    create table(:kb_relations) do
      add :from_document_id, references(:kb_documents, on_delete: :delete_all), null: false
      add :to_document_id, references(:kb_documents, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :author, :string, null: false
      add :note, :text

      timestamps()
    end

    create index(:kb_relations, [:to_document_id, :kind])
    create index(:kb_relations, [:from_document_id])

    # --- checks: the staleness sweep log ----------------------------------
    # Each FACT carries a runnable command and a fails_when. A scheduled runner
    # re-runs them and records the verdict here. This is the feature nothing in
    # the current system provides, and it is what catches a claim that has
    # quietly stopped being true.
    create table(:kb_checks) do
      add :document_id, references(:kb_documents, on_delete: :delete_all), null: false
      add :ran_at, :utc_datetime, null: false
      add :verdict, :string, null: false
      add :output, :text
      add :runner, :string

      timestamps()
    end

    create index(:kb_checks, [:document_id, :ran_at])
    create index(:kb_checks, [:verdict])

    # --- FTS5 over revision bodies ----------------------------------------
    # DEFAULT TOKENIZER, DELIBERATELY -- matching forum_posts_fts.
    #
    # An earlier draft added `tokenize="unicode61 tokenchars '_.#$-'"` on the
    # theory that the default splits identifiers and is why "search fails on
    # identifiers, works on prose". MEASURED 2026-09-08 against exqlite's
    # bundled SQLite, both arms, same content:
    #
    #   term              default  custom
    #   "func_00336B88"   1        1      <- REFUTED: FTS5 tokenises the QUERY
    #   "#22585"          1        1         the same way, so a quoted phrase
    #   "0x00336B88"      1        1         matches adjacent tokens anyway
    #   func_0033*        1        1      <- no prefix benefit either
    #   00336B88          1        0      <- and the custom one LOSES this
    #
    # So the custom tokenizer fixed nothing, gained nothing, and broke search
    # for a bare address fragment. Dropped.
    #
    # ⚠️ The real cause of the identifier complaint is still UNKNOWN. A better
    # hypothesis, from the same probe: an UNQUOTED query containing '/' or '-'
    # RAISES (text/235FE8 and a-b both errored on BOTH arms), because those are
    # FTS5 query syntax. If Forum.search/2 passes user input unquoted, such a
    # search errors and may surface to the caller as "no results". Test that
    # before changing any tokenizer.
    execute(
      """
      CREATE VIRTUAL TABLE kb_revisions_fts USING fts5(
        body_md,
        title,
        content='kb_revisions',
        content_rowid='id'
      )
      """,
      "DROP TABLE IF EXISTS kb_revisions_fts"
    )

    execute(
      """
      CREATE TRIGGER kb_revisions_ai AFTER INSERT ON kb_revisions BEGIN
        INSERT INTO kb_revisions_fts(rowid, body_md, title)
        VALUES (new.id, new.body_md, '');
      END
      """,
      "DROP TRIGGER IF EXISTS kb_revisions_ai"
    )

    execute(
      """
      CREATE TRIGGER kb_revisions_ad AFTER DELETE ON kb_revisions BEGIN
        INSERT INTO kb_revisions_fts(kb_revisions_fts, rowid, body_md, title)
        VALUES ('delete', old.id, old.body_md, '');
      END
      """,
      "DROP TRIGGER IF EXISTS kb_revisions_ad"
    )
  end
end
