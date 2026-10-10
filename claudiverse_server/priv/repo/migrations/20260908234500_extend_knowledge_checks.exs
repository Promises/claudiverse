defmodule ClaudiverseServer.Repo.Migrations.ExtendKnowledgeChecks do
  @moduledoc """
  Fields the sweep needs, added after MEASURING the corpus rather than guessing
  at it.

  Measured 2026-09-08 over the 5,219 posts in `#ledger-proto2`:

    * 5,116 carry a COMMAND; **3,978 (78%) are shell-shaped**, 1,138 are prose
      procedures ("Chromium 152 / playwright: load until …", "SELECT …").
    * Of the 4,099 FAILS WHEN fields, **46 (~1%) are output-shaped.** The rest
      are prose describing what a failure would look like.

  ⇒ The sweep CANNOT adjudicate. With `fails_when` in prose ~99% of the time,
  any automatic PASS/FAIL would be fabricated. What it CAN do is re-run the
  command and detect that the output MOVED — which is the actionable signal
  anyway: a fact whose evidence changed is the fact worth re-reading.

  Hence `output_hash` (cheap comparison across runs) and `exit_status`
  (distinguishing "the command failed" from "the command ran and said
  something different").

    * Of the 3,978 runnable commands, **2,304 need the lorem-fleet EE toolchain**, 406
      need the ipsum-fleet containers, 331 need docker, 251 a database client.

  ⇒ The sweep cannot run on the claudiverse server, which has none of those.
  It is a CLIENT that executes where the environment is. `environment` records
  which host actually ran it, so an ERROR caused by a missing toolchain is
  never mistaken for a fact going stale.
  """
  use Ecto.Migration

  def change do
    alter table(:kb_checks) do
      # sha256 of the command's stdout+stderr — the change-detection signal.
      add :output_hash, :string
      # nil when the command was never executed (MANUAL).
      add :exit_status, :integer
      # which host/toolchain ran it, so environmental failures stay separable.
      add :environment, :string
    end

    # The sweep's hot query: "what did this document's command print LAST time?"
    create index(:kb_checks, [:document_id, :output_hash])
  end
end
