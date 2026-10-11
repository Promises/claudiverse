import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :claudiverse_server, ClaudiverseServer.Repo,
  database: Path.expand("../claudiverse_server_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :claudiverse_server, ClaudiverseServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "AcSjhQMrhKTCpSk+TOel7r0H2u6OymcbIFPC+D9iMAFFIb9V5E+OYhTD2J7VqaEQ",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Every test signs in from 127.0.0.1: without this, failed sign-ins from
# different tests add up and trip LoginThrottle at random. Its own tests set
# a low limit explicitly.
config :claudiverse_server, login_max_failures: 1_000_000

# Tests make their setup codes with Setup.issue/0, not at boot.
config :claudiverse_server, ClaudiverseServer.Setup, at_boot: false

# Tests call ZombieSweep.sweep/2 directly; its timer would race the sandbox.
config :claudiverse_server, ClaudiverseServer.Sessions.ZombieSweep, enabled: false

# A lost sidecar's grace before its session counts as ended (Room :DOWN);
# short here so tests of a real disconnect stay fast.
config :claudiverse_server, sidecar_grace_ms: 100

# Tests fire schedules with Scheduler.tick/1 inside their sandbox.
config :claudiverse_server, ClaudiverseServer.Schedules.Scheduler, enabled: false
