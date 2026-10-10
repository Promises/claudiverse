defmodule ClaudiverseServerWeb.Router do
  use ClaudiverseServerWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug ClaudiverseServerWeb.Plugs.Auth
  end

  # MCP channel streams (text/event-stream) and hook calls: no `accepts`
  # restriction, which would refuse the SSE GET.
  scope "/api", ClaudiverseServerWeb do
    pipe_through [:authenticated]

    post "/mcp/seat/:seat", McpController, :post
    get "/mcp/seat/:seat", McpController, :stream
    delete "/mcp/seat/:seat", McpController, :delete
    post "/hooks/seat/:seat/pretooluse", HookController, :pretooluse
    post "/hooks/seat/:seat/permissionrequest", HookController, :permission_request
    get "/seats/whoami", SeatController, :whoami
    get "/seats/:seat/inbox", InboxController, :poll
  end

  scope "/api", ClaudiverseServerWeb do
    pipe_through :api

    # Unauthenticated liveness probe (container HEALTHCHECK + deploy smoke test).
    get "/health", HealthController, :index

    # No open registration. The FIRST account signs up with the setup code
    # the server logs while it has none (ClaudiverseServer.Setup); later
    # ones are made with `mix claudiverse.register`.
    post "/auth/login", AuthController, :login
    get "/setup", AuthController, :setup_status
    post "/setup", AuthController, :setup
  end

  scope "/api", ClaudiverseServerWeb do
    pipe_through [:api, :authenticated]

    delete "/auth/logout", AuthController, :logout
    get "/me", AuthController, :me
    get "/incidents", IncidentController, :index

    get "/sessions", SessionController, :index
    post "/sessions", SessionController, :create
    get "/sessions/:id", SessionController, :show
    delete "/sessions/:id", SessionController, :delete
    post "/sessions/:id/title", SessionController, :set_title
    post "/sessions/:id/permission_mode", SessionController, :permission_mode
    post "/sessions/:id/access", SessionController, :access
    post "/sessions/:id/notify", SessionController, :notify
    post "/sessions/:id/human_requests/resolve", HumanRequestController, :resolve
    post "/human_requests", HumanRequestController, :create
    post "/app/builds", AppBuildController, :create
    get "/hosts", HostController, :index
    get "/hosts/:host/recent_dirs", HostController, :recent_dirs
    get "/hosts/:host/ls", HostController, :ls
    post "/hosts/:host/spawn", HostController, :spawn
    post "/hosts/:host/token", HostController, :mint_token
    post "/hosts/:host/roots", HostController, :add_root
    delete "/hosts/:host/roots", HostController, :remove_root
    post "/runners/heartbeat", RunnerController, :heartbeat
    get "/fleets", RunnerController, :fleets
    get "/profiles", ProfileController, :index
    post "/profiles", ProfileController, :create
    get "/profiles/:id", ProfileController, :show
    patch "/profiles/:id", ProfileController, :update
    delete "/profiles/:id", ProfileController, :delete
    post "/profiles/:id/start", ProfileController, :start
    post "/profiles/:id/stop", ProfileController, :stop
    post "/profiles/:id/restart", ProfileController, :restart
    post "/profiles/:id/rename", ProfileController, :rename
    get "/sessions/:id/adopt_preview", AdoptController, :preview
    post "/sessions/:id/adopt", AdoptController, :adopt
    get "/tokens", TokenController, :index
    delete "/tokens/:id", TokenController, :delete
    post "/sessions/:id/mirror", SessionController, :mirror
    post "/sessions/:id/stop", HostController, :stop
    post "/sessions/:id/resume", HostController, :resume
    get "/app/builds/latest", AppBuildController, :latest
    get "/app/builds/:id/apk", AppBuildController, :apk
    get "/human_requests", HumanRequestController, :index
    post "/sessions/:id/files", FileController, :create
    get "/files/:file_id", FileController, :show

    post "/notify/subscribe", NotifyController, :subscribe
    post "/notify/ack", NotifyController, :ack
    get "/notify/pending", NotifyController, :pending
    get "/notify/status", NotifyController, :status
    post "/notify/send", NotifyController, :send
    post "/notify/report", NotifyController, :report

    # Discussion forum (pull to read/search; opt-in subscribe routes new-post
    # pings through Notifications.Router). See ForumController.
    get "/forum/channels", ForumController, :channels
    post "/forum/channels", ForumController, :create_channel
    get "/forum/channels/:slug/posts", ForumController, :posts
    post "/forum/posts", ForumController, :create_post
    get "/forum/posts/:id", ForumController, :show
    get "/forum/search", ForumController, :search

    # --- knowledge store (durable documents; distinct from the forum feed) ---
    # --- Anthropic account pool (AnthropicAuths) ---------------------------
    # Seat-facing: lease a valid token, report a 429, report a 401.
    post "/anthropic_auths/lease", AnthropicAuthController, :lease
    post "/anthropic_auths/:id/rate_limited", AnthropicAuthController, :rate_limited
    post "/anthropic_auths/:id/unauthorized", AnthropicAuthController, :unauthorized

    # Panel-facing: enrol, inspect, poll usage, remove.
    get "/anthropic_auths", AnthropicAuthController, :index
    post "/anthropic_auths/authorize", AnthropicAuthController, :authorize
    post "/anthropic_auths/complete", AnthropicAuthController, :complete
    post "/anthropic_auths/:id/usage", AnthropicAuthController, :refresh_usage
    delete "/anthropic_auths/:id", AnthropicAuthController, :delete
    post "/anthropic_auths/:id/preferred", AnthropicAuthController, :preferred

    post "/kb/documents", KnowledgeController, :create
    get "/kb/documents/:id", KnowledgeController, :show
    post "/kb/documents/:id/revisions", KnowledgeController, :add_revision
    get "/kb/documents/:id/history", KnowledgeController, :history
    get "/kb/search", KnowledgeController, :search
    get "/kb/anchors/:type/:value", KnowledgeController, :anchor
    get "/kb/address/:address", KnowledgeController, :address
    post "/kb/symbols", KnowledgeController, :record_symbol
    get "/kb/symbols/:name", KnowledgeController, :resolve_symbol
    post "/kb/relations", KnowledgeController, :relate
    get "/kb/health", KnowledgeController, :health
    get "/kb/sweep/worklist", KnowledgeController, :sweep_worklist
    post "/kb/sweep/runs", KnowledgeController, :record_run
    get "/kb/sweep/summary", KnowledgeController, :sweep_summary

    # Component B — submissions
    get "/kb/submissions/blind-gates", SubmissionController, :blind_gates
    post "/kb/submissions", SubmissionController, :create
    get "/kb/submissions", SubmissionController, :index
    get "/kb/submissions/:id", SubmissionController, :show
    post "/kb/submissions/:id/gates", SubmissionController, :gate
    post "/kb/submissions/:id/integrate", SubmissionController, :integrate
    post "/kb/submissions/:id/revert", SubmissionController, :revert

    # Component E — tasks
    post "/tasks/health", TaskController, :health
    post "/tasks/claim", TaskController, :claim
    post "/tasks", TaskController, :create
    get "/tasks", TaskController, :index
    get "/tasks/:id", TaskController, :show
    patch "/tasks/:id", TaskController, :update
    put "/tasks/:id", TaskController, :update
    get "/tasks/:id/chain", TaskController, :chain
    post "/tasks/:id/ready", TaskController, :ready
    post "/tasks/:id/start", TaskController, :start
    post "/tasks/:id/progress", TaskController, :progress
    post "/tasks/:id/complete", TaskController, :complete
    post "/tasks/:id/release", TaskController, :release
    post "/tasks/:id/supersede", TaskController, :supersede
    post "/tasks/:id/deps", TaskController, :add_dep

    # Component D — periodic full builds
    get "/builds/due", BuildController, :due
    get "/builds/suspects", BuildController, :suspects
    post "/builds", BuildController, :create
    get "/builds", BuildController, :index
    get "/kb/stale", KnowledgeController, :stale
    post "/kb/checks", KnowledgeController, :record_check
    get "/forum/subscriptions", ForumController, :subscriptions
    post "/forum/subscribe", ForumController, :subscribe
    post "/forum/unsubscribe", ForumController, :unsubscribe

    # Work-tracker post mutations (edit-in-place / prune / status board). All
    # Bearer-gated; any authenticated fleet member may act (shared account).
    patch "/forum/posts/:id", ForumController, :edit
    delete "/forum/posts/:id", ForumController, :delete
    post "/forum/posts/:id/archive", ForumController, :archive
    post "/forum/posts/:id/unarchive", ForumController, :unarchive
    post "/forum/posts/:id/pin", ForumController, :pin
    post "/forum/posts/:id/unpin", ForumController, :unpin
    post "/forum/posts/:id/resolve", ForumController, :resolve
    post "/forum/posts/:id/status", ForumController, :set_status
    post "/forum/posts/:id/assign", ForumController, :assign
    # Atomic claim-if-unowned — 200 to exactly one caller, 409 to the rest.
    # Deliberately NOT the same endpoint as :assign. Assign is a manager
    # REASSIGNING work: unconditional, and correct that way. Claim is a runner
    # RACING its peers: conditional, and the only safe way to take a task.
    post "/forum/posts/:id/claim", ForumController, :claim

    # Per-agent handoff / continuity state. PULL-ONLY: set enqueues no ping,
    # nobody is alerted; a successor reads on takeover. `set` is scoped to the
    # caller's own role (`self`).
    post "/forum/handoff/set", ForumController, :handoff_set
    get "/forum/handoffs", ForumController, :handoffs
    get "/forum/handoff/:role", ForumController, :handoff_get

  end
end
