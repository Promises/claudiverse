defmodule ClaudiverseServer.Repo.Migrations.AddConversationIdToSessions do
  @moduledoc """
  The Claude conversation a seat runs, when it is not its claude_session_id.
  A seat started with `claude --resume X` reports a placeholder session id
  (the sidecar keeps it on purpose; see SidecarClient.js resolveTitle), so
  resuming THAT seat again needs X. Set by the server after a resume it
  started; null means claude_session_id is the conversation.
  """
  use Ecto.Migration

  def change do
    alter table(:sessions) do
      add :conversation_id, :string
    end
  end
end
