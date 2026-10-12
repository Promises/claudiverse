defmodule ClaudiverseServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ClaudiverseServerWeb.Telemetry,
      ClaudiverseServer.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:claudiverse_server, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:claudiverse_server, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ClaudiverseServer.PubSub},
      {Registry, keys: :unique, name: ClaudiverseServer.Sessions.Registry},
      ClaudiverseServer.Sessions.Supervisor,
      # Stops "running" rows nothing can stop any more (no Room, long idle).
      ClaudiverseServer.Sessions.ZombieSweep,
      ClaudiverseServer.Notifications.Router,
      ClaudiverseServer.Knowledge.Custodian,
      # Serialises Anthropic token refresh per account. Not an optimisation:
      # concurrent refreshes can leave one caller holding a superseded token,
      # and the failure is silent (both get HTTP 200) until a later 401.
      ClaudiverseServer.AnthropicAuths.RefreshLock,
      # Slow background read of each account's usage. Also the only way a rate
      # limit gets noticed without a client patch: seats run stock and cannot
      # report a 429 themselves.
      ClaudiverseServer.AnthropicAuths.UsagePoller,
      # The API proxy (ClaudiverseServerWeb.ProxyPlug): its upstream client and
      # one observer per Claude session it carries.
      {Finch, name: ClaudiverseServer.Proxy.Finch, pools: %{default: [size: 64, conn_max_idle_time: 60_000]}},
      {Registry, keys: :unique, name: ClaudiverseServer.Proxy.Registry},
      {DynamicSupervisor, name: ClaudiverseServer.Proxy.Supervisor, strategy: :one_for_one},
      # The pool credential pooled proxy seats go out with (Proxy.Credentials).
      ClaudiverseServer.Proxy.Credentials,
      # Live channel streams and held questions, per seat (SeatLinks).
      ClaudiverseServer.SeatLinks,
      # AskUserQuestion holds the mod polls, and answers between its polls.
      ClaudiverseServer.QuestionHolds,
      # Prompts for seats that take them through an asyncRewake hook.
      ClaudiverseServer.SeatInbox,
      ClaudiverseServer.LoginThrottle,
      # The first account's one-time setup code, while there is no account.
      ClaudiverseServer.Setup,
      ClaudiverseServer.Runners,
      # Scheduled prompts: fires due schedules every 30 s, and first at boot.
      ClaudiverseServer.Schedules.Scheduler,
      # A seat whose turn died on an empty pool or a restart gets one
      # "continue" when the server can serve it again (AutoResume).
      ClaudiverseServer.AutoResume.Server,
    ] ++ ClaudiverseServer.Hosts.child_specs() ++ [
      ClaudiverseServerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ClaudiverseServer.Supervisor]

    # Attached before the tree starts so no query — migrations included — runs
    # unobserved. See ClaudiverseServer.SlowQueryLog for why queue time matters.
    ClaudiverseServer.SlowQueryLog.attach()
    # Every 5xx, recorded on the /data volume so a count survives a swap.
    ClaudiverseServer.IncidentLog.attach()

    Supervisor.start_link(children, opts)
  end

  # Before the tree stops: a response still streaming through the proxy now is
  # cut by this stop, and must read in flight at the next boot (AutoResume).
  @impl true
  def prep_stop(state) do
    ClaudiverseServer.AutoResume.Server.shutting_down()
    state
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ClaudiverseServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
