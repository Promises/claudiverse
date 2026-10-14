defmodule ClaudiverseServer.AnthropicAuths.UsageSample do
  @moduledoc "One usage reading of one pool account (UsageHistory)."
  use Ecto.Schema

  schema "usage_samples" do
    belongs_to :anthropic_auth, ClaudiverseServer.AnthropicAuths.AnthropicAuth
    field :at, :utc_datetime
    field :weekly_pct, :float
    field :weekly_resets_at, :utc_datetime
    field :session_pct, :float
    field :session_resets_at, :utc_datetime
  end
end
