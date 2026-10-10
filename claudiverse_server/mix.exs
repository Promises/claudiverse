defmodule ClaudiverseServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :claudiverse_server,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ClaudiverseServer.Application, []},
      # 🔴 :inets and :ssl are REQUIRED IN THE RELEASE, not just in dev.
      # AnthropicAuths.OAuth talks to Anthropic with :httpc (deliberately, to
      # avoid adding an HTTP client dependency for four calls). Under `mix run`
      # the whole of OTP is on the path so it works; a Mix RELEASE ships only
      # the applications listed here, so :httpc was absent in production and
      # enrolment failed with a bare HTTP 500.
      # ⚠️ Nothing local caught this: every test I wrote used seeded data and
      # never made a real HTTP call, so the one path that needed these was the
      # one path never exercised before deploy.
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      # Streaming HTTP client for the API proxy (ClaudiverseServerWeb.ProxyPlug).
      # :httpc's streaming mode cannot halt mid-response, which an interrupted
      # Claude Code turn needs.
      {:finch, "~> 0.19"},
      {:bcrypt_elixir, "~> 3.0"},
      {:corsica, "~> 2.1"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
