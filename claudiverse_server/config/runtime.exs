import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/claudiverse_server start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :claudiverse_server, ClaudiverseServerWeb.Endpoint, server: true
end


if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/claudiverse_server/claudiverse_server.db
      """

  config :claudiverse_server, ClaudiverseServer.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # Scheduled verified snapshots. Off unless SNAPSHOT_DIR is set, so enabling
  # it is a deliberate act with a chosen destination — never a default that
  # quietly fills whatever directory the server happened to start in.
  config :claudiverse_server, ClaudiverseServer.Knowledge.Custodian,
    enabled: !is_nil(System.get_env("SNAPSHOT_DIR")),
    dir: System.get_env("SNAPSHOT_DIR"),
    keep: String.to_integer(System.get_env("SNAPSHOT_KEEP") || "7"),
    every_ms: String.to_integer(System.get_env("SNAPSHOT_EVERY_HOURS") || "24") * 3_600_000

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  # Public-facing URL config. Behind a TLS-terminating reverse proxy set
  # PHX_SCHEME=https and PHX_URL_PORT=443; for plain-HTTP testing the defaults
  # (http on the bound PORT) are correct.
  url_scheme = System.get_env("PHX_SCHEME") || "http"
  url_port = String.to_integer(System.get_env("PHX_URL_PORT") || Integer.to_string(port))

  # The web SPA is served from a different origin and talks to this API
  # cross-origin (CORS is "*"). WebSocket/LiveView origin checking would reject
  # those connections, so default to disabled; set CHECK_ORIGIN to a
  # comma-separated allowlist (or "true"/"false") to tighten it.
  check_origin =
    case System.get_env("CHECK_ORIGIN") do
      nil -> false
      "false" -> false
      "true" -> true
      list -> String.split(list, ",", trim: true)
    end

  config :claudiverse_server, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :claudiverse_server, ClaudiverseServerWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
    check_origin: check_origin,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :claudiverse_server, ClaudiverseServerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :claudiverse_server, ClaudiverseServerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
