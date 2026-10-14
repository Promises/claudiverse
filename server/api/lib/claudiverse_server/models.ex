defmodule ClaudiverseServer.Models do
  @moduledoc """
  The models a seat can run, served to the web panel and the apps
  (GET /api/models) so their pickers cannot drift apart. The list is
  priv/models.json, read when the server is compiled.

  Each model, in display order: `id` (exact, as `/model` and `--model` take
  it), `label`, `family`, `one_m` (its bare id has a 1M context window),
  `accepts_1m_suffix` (`<id>[1m]` gives it the 1M window: Claude Code's
  "optIn"; false where `one_m`, and where Claude Code ignores the suffix),
  `since` (the first Claude Code version that knows it, or null), `older`
  (an earlier generation, folded away). `aliases` are names Claude Code
  resolves to a model of its choosing. Taken from Claude Code's own model
  catalog and its 1M rule (2.1.296: `native_1m` is native; `supports_1m_beta`
  is optIn except for Claude 3, Opus 4.0, 4.1 and 4.5, and Haiku 4.5): update
  the file when a model is released.
  """

  @path Path.expand("../../priv/models.json", __DIR__)
  @external_resource @path
  @catalog @path |> File.read!() |> Jason.decode!()

  @doc "The list as GET /api/models serves it: %{\"models\", \"aliases\", \"source\"}."
  def catalog, do: @catalog
end
