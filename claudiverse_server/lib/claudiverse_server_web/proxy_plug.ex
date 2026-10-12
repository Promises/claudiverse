defmodule ClaudiverseServerWeb.ProxyPlug do
  @moduledoc """
  An observing pass-through proxy between Claude Code and the Anthropic API,
  mounted at `/proxy`. A seat opts in at launch:

      ANTHROPIC_BASE_URL=http://<server>/proxy/seat/<title>
      ANTHROPIC_CUSTOM_HEADERS="X-Claudiverse-Token: <claudiverse api token>"
      CLAUDE_CODE_GATEWAY_HINT_HEADERS=1

  Nothing else about the seat changes — binary, sidecar, cv-spawn and runner
  stay as they are — so this runs BESIDE the patched-binary system. A seat can
  feed both, and the two are compared on the same traffic.

  Mounted in the endpoint BEFORE `Plug.Parsers`: the body must reach the API
  byte for byte, and a request body here is the whole conversation (hundreds
  of KB, several MB late in a long session).

  ## Invariants

  - Observation never touches the traffic. Bytes are forwarded as they arrive;
    parsing and bookkeeping happen in `ClaudiverseServer.Proxy.Observer`, by
    cast, so neither a parse failure nor SQLite is ever on the path of a model
    call.
  - A seat's own `Authorization` goes upstream untouched and is never stored.
  - A seat that sends the placeholder `Bearer cv-pool`
    (`CLAUDE_CODE_OAUTH_TOKEN=cv-pool`) is a POOLED seat: its requests go out
    with the pool's current token (`ClaudiverseServer.Proxy.Credentials`), and
    a 401/429 is held, reported and retried on the next account instead of
    reaching Claude Code. Pool tokens never leave the server except towards
    the API.
  - A seat that keeps its OWN login and sends `X-Claudiverse-Pool: 1` is
    pooled the same way: its model requests go out with the pool's token
    (its own is replaced, never relayed), with the same failover. The seat
    needs its own login for what never reaches the proxy: Claude Code's
    feature flags are fetched from api.anthropic.com directly, and a seat
    holding only the placeholder falls back to anonymous flags, which turns
    plugin mods off (the claudiverse-seat mod, profiles' stock+mod runtime).
  - `X-Claudiverse-Observe: off` relays without observing: a seat that
    mirrors itself (the mod) would otherwise be recorded twice.
  - The claudiverse token is required. Without it this would be an open relay
    to the Anthropic API for anything on the network.
  """
  @behaviour Plug

  import Plug.Conn
  require Logger

  alias ClaudiverseServer.Accounts
  alias ClaudiverseServer.AutoResume
  alias ClaudiverseServer.Proxy.{Credentials, Observer, Request}

  @finch ClaudiverseServer.Proxy.Finch
  @hop_by_hop ~w(connection keep-alive proxy-connection transfer-encoding upgrade te trailer host content-length)
  # Consumed here, never passed on. accept-encoding is dropped so the API
  # answers uncompressed and the stream can be read as it passes.
  @strip_upstream ~w(x-claudiverse-token x-claudiverse-seat x-claudiverse-provides x-claudiverse-pool x-claudiverse-observe accept-encoding)
  @provides ~w(mirror idle compact)
  @max_body 64 * 1024 * 1024
  # Accounts one request may try before its 429 is relayed as-is.
  @pool_attempts 3

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["proxy", "_status"]} = conn, _opts) do
    with {:ok, _user} <- authenticate(conn) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{sessions: Observer.status()}))
      |> halt()
    else
      _ -> conn |> api_error(403, "permission_error", "cv-proxy: missing or invalid X-Claudiverse-Token") |> halt()
    end
  end

  def call(%Plug.Conn{path_info: ["proxy" | parts]} = conn, _opts) do
    case authenticate(conn) do
      {:ok, user} ->
        {seat, path} = Request.route(parts, conn.req_headers)
        proxy(conn, user, seat, path)

      # Claude Code's reachability probe (HEAD <base>/api/hello) carries none
      # of ANTHROPIC_CUSTOM_HEADERS, so it can never authenticate, and a 403
      # read as "API unreachable". It carries and reveals nothing: answer it.
      :error ->
        if conn.method in ["HEAD", "GET"] and Enum.take(parts, -2) == ["api", "hello"],
          do: conn |> send_resp(200, "") |> halt(),
          else: refuse(conn)
    end
  end

  def call(conn, _opts), do: conn

  # 403, not 401: a 401 tells Claude Code its OAuth token is bad and starts a
  # refresh, which is not what went wrong.
  defp refuse(conn),
    do: conn |> api_error(403, "permission_error", "cv-proxy: missing or invalid X-Claudiverse-Token") |> halt()

  defp authenticate(conn) do
    with token when is_binary(token) <- Request.header(conn.req_headers, "x-claudiverse-token"),
         {:ok, user} <- Accounts.fetch_user_by_api_token(token) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp proxy(conn, user, seat, path) do
    case read_full_body(conn, []) do
      {:ok, body, conn} ->
        observe =
          if Request.header(conn.req_headers, "x-claudiverse-observe") == "off",
            do: nil,
            else: observe_request(conn, user, seat, path, body)

        resume = resume_key(conn, user, seat, path, body)

        if pooled?(conn.req_headers),
          do: forward_pooled(conn, path, body, observe, seat, resume),
          else: forward(conn, path, body, observe, nil, resume)

      {:error, reason} ->
        conn |> api_error(413, "request_too_large", "cv-proxy: #{inspect(reason)}") |> halt()
    end
  end

  # --- Pooled seats ----------------------------------------------------------

  defp pooled?(headers) do
    Request.header(headers, "authorization") == "Bearer " <> Credentials.placeholder() or
      Request.header(headers, "x-claudiverse-pool") == "1"
  end
  #
  # The seat sent the placeholder; the request goes out with the pool's current
  # token. A 429 or 401 arrives as a status line before any body, so it is HELD
  # rather than relayed: the pool is told, and the same request is retried on
  # the account it hands back. Claude Code never sees the 429.

  defp forward_pooled(conn, path, body, observe, seat, resume) do
    case Credentials.current(seat) do
      {:ok, lease} -> pooled_attempt(conn, path, body, observe, seat, lease, @pool_attempts, resume)
      {:error, reason} -> no_pool_account(conn, reason, resume)
    end
  end

  defp pooled_attempt(conn, path, body, observe, seat, lease, left, resume) do
    case forward(conn, path, body, observe, lease, resume) do
      {:held, %{status: 429} = acc} when left > 1 ->
        if limit_reached?(acc.headers) do
          case Credentials.rate_limited(lease.auth_id, resets_at(acc.headers), seat) do
            {:ok, next} -> pooled_attempt(acc.conn, path, body, observe, seat, next, left - 1, resume)
            {:error, _} -> relay_held(acc, observe)
          end
        else
          # A short or unexplained 429 is not an exhausted account. Cooling one
          # for it would take a healthy account out for 15 minutes; Claude
          # Code's own retry handles it.
          relay_held(acc, observe)
        end

      {:held, %{status: 401} = acc} when left > 1 ->
        case Credentials.unauthorized(lease.auth_id, seat) do
          {:ok, next} -> pooled_attempt(acc.conn, path, body, observe, seat, next, left - 1, resume)
          {:error, _} -> relay_held(acc, observe)
        end

      {:held, acc} ->
        relay_held(acc, observe)

      %Plug.Conn{} = conn ->
        conn
    end
  end

  # Fail over only when the account itself is spent: the API says so, or its
  # reset is more than a minute out. Same threshold the sidecar's 012 used
  # ("Don't switch for a short wait"), measured there to be the right call.
  defp limit_reached?(headers) do
    Request.header(headers, "anthropic-ratelimit-unified-status") == "rejected" or
      case resets_at(headers) do
        %DateTime{} = at -> DateTime.diff(at, DateTime.utc_now()) > 60
        nil -> false
      end
  end

  defp resets_at(headers) do
    with v when is_binary(v) <- Request.header(headers, "anthropic-ratelimit-unified-reset"),
         {secs, _} <- Integer.parse(v),
         {:ok, at} <- DateTime.from_unix(secs) do
      at
    else
      _ -> nil
    end
  end

  defp relay_held(acc, observe) do
    resp_headers = for {k, v} <- acc.headers, k not in @hop_by_hop, do: {k, v}
    raw = IO.iodata_to_binary(acc.chunks)

    conn =
      acc.conn
      |> merge_resp_headers(resp_headers)
      |> no_transform()
      |> send_resp(acc.status, raw)

    finish_observe(observe, acc)
    halt(conn)
  end

  defp no_pool_account(conn, reason, resume) do
    Logger.warning("[proxy] pooled request refused: no pool account (#{inspect(reason)})")
    # The seat's turn ends on this once Claude Code's retries run out: it gets
    # a continue when an account is leasable again.
    if resume && reason == :no_available_auth, do: AutoResume.Server.refused(resume, "cv-proxy: no pool account is available (:no_available_auth)")

    conn
    |> api_error(429, "rate_limit_error", "cv-proxy: no pool account is available (#{inspect(reason)})")
    |> halt()
  end

  defp read_full_body(conn, acc) do
    case read_body(conn, length: 8_000_000, read_timeout: 60_000) do
      {:ok, chunk, conn} ->
        body = IO.iodata_to_binary([acc, chunk])
        if byte_size(body) > @max_body, do: {:error, :too_large}, else: {:ok, body, conn}

      {:more, chunk, conn} ->
        if IO.iodata_length([acc, chunk]) > @max_body,
          do: {:error, :too_large},
          else: read_full_body(conn, [acc, chunk])

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Returns the response observer for a model request, or nil. Never raises:
  # whatever happens here, the request still goes upstream.
  defp observe_request(conn, user, seat, path, body) do
    sid = Request.header(conn.req_headers, "x-claude-code-session-id")

    if conn.method == "POST" and sid not in [nil, ""] and String.starts_with?(path, "/v1/messages") do
      json = Jason.decode!(body)
      class = Request.classify(conn.req_headers, json)
      agent_id = Request.header(conn.req_headers, "x-claude-code-agent-id")

      Observer.request(sid, user.id, seat, %{
        class: class,
        agent_id: agent_id,
        messages: json["messages"] || [],
        model: json["model"],
        account: Request.account(json),
        provides: provides(conn.req_headers)
      })

      fn status, headers, raw, aborted ->
        Observer.response(sid, %{
          class: class,
          agent_id: agent_id,
          status: status,
          headers: headers,
          content_type: Request.header(headers, "content-type"),
          raw: raw,
          aborted: aborted
        })
      end
    end
  rescue
    e ->
      Logger.warning("[proxy] request observation failed: #{Exception.message(e)}")
      nil
  end

  # Relays one exchange. Returns the halted conn, or `{:held, acc}` when a
  # pooled request was answered 401/429 and nothing was sent to the client yet.
  # What a seat that retired patches hands to the proxy (see Proxy.Observer).
  # Unknown names are ignored rather than trusted.
  defp provides(headers) do
    case Request.header(headers, "x-claudiverse-provides") do
      nil -> []
      v -> v |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.filter(&(&1 in @provides))
    end
  end

  # Whose main-loop model call this is, for auto-resume (AutoResume): the seat
  # it is reported for when its stream starts, ends or is refused. Nil for
  # anything else, and when tracking is off.
  defp resume_key(conn, user, seat, path, body) do
    if is_binary(seat) and conn.method == "POST" and path == "/v1/messages" and
         Application.get_env(:claudiverse_server, AutoResume, [])[:track] != false and
         Request.main_loop?(conn.req_headers, body) do
      {user.id, seat, Request.header(conn.req_headers, "x-claude-code-session-id")}
    end
  end

  defp forward(conn, path, body, observe, lease, resume) do
    upstream = Application.get_env(:claudiverse_server, :proxy_upstream, "https://api.anthropic.com")
    url = upstream <> path <> if(conn.query_string == "", do: "", else: "?" <> conn.query_string)

    headers =
      for {k, v} <- conn.req_headers, k not in @hop_by_hop, k not in @strip_upstream, do: {k, v}

    headers =
      case lease do
        nil -> headers
        %{access_token: t} -> List.keystore(headers, "authorization", 0, {"authorization", "Bearer " <> t})
      end

    req = Finch.build(conn.method, url, headers, body)
    acc = %{conn: conn, status: nil, headers: [], chunks: [], aborted: false, pooled: lease != nil, held: false, sse_error: nil,
            resume: resume, streaming: false}

    result =
      Finch.stream_while(req, @finch, acc, &on_stream/2,
        # Between chunks, not overall: a long generation streams for minutes.
        receive_timeout: 600_000
      )

    # However it ended; `clean` when the whole response reached the seat. A
    # server that stops kills this process before here, or ends the stream
    # unclean, which is how a restart leaves the seat in flight (AutoResume).
    case result do
      {:ok, %{streaming: true, resume: key} = acc} -> AutoResume.Server.stream_ended(key, not acc.aborted and acc.sse_error == nil)
      {:error, _, %{streaming: true, resume: key}} -> AutoResume.Server.stream_ended(key, false)
      _ -> :ok
    end

    case result do
      {:ok, %{held: true} = acc} ->
        {:held, acc}

      {:ok, %{conn: conn} = acc} ->
        log_stream_end(conn, acc, nil)
        finish_observe(observe, acc)
        halt(conn)

      {:error, error, %{conn: conn} = acc} ->
        if acc.status == nil do
          Logger.warning("[proxy] upstream error before response: #{inspect(error)}")
          conn |> api_error(502, "api_error", "cv-proxy: upstream unreachable: #{inspect(error)}") |> halt()
        else
          log_stream_end(conn, acc, error)
          finish_observe(observe, %{acc | aborted: true})
          halt(conn)
        end
    end
  end

  # How a streamed response ended, when not cleanly: Claude Code says only
  # "Server error mid-response" for all of these, and Phoenix's "Chunked 200"
  # line is written when the headers go out, so nothing else tells them apart.
  # MEASURED 2026-10-07 23:57: lorem-orchestrator's turn died that way and
  # the log could not say whether Anthropic or the proxy ended it.
  defp log_stream_end(conn, acc, upstream_error) do
    cond do
      upstream_error ->
        Logger.warning("[proxy] #{conn.request_path}: upstream stream failed mid-response (#{inspect(upstream_error)}), #{IO.iodata_length(acc.chunks)} bytes relayed")

      acc.aborted ->
        Logger.info("[proxy] #{conn.request_path}: the client hung up mid-stream (an interrupt)")

      acc.sse_error ->
        Logger.warning("[proxy] #{conn.request_path}: upstream sent an error event mid-stream: #{acc.sse_error}")

      true ->
        :ok
    end
  end

  defp on_stream({:status, status}, acc),
    do: {:cont, %{acc | status: status, held: acc.pooled and status in [401, 429]}}

  defp on_stream({:headers, headers}, %{held: true} = acc), do: {:cont, %{acc | headers: headers}}

  defp on_stream({:headers, headers}, acc) do
    resp_headers = for {k, v} <- headers, k not in @hop_by_hop, do: {k, v}

    conn =
      acc.conn
      |> merge_resp_headers(resp_headers)
      |> no_transform()
      |> send_chunked(acc.status)

    # The model answered: the seat's turn is alive, and a response is in
    # flight to it until this exchange ends.
    streaming = acc.resume != nil and acc.status == 200
    if streaming, do: AutoResume.Server.stream_started(acc.resume)

    {:cont, %{acc | conn: conn, headers: headers, streaming: streaming}}
  end

  defp on_stream({:data, data}, %{held: true} = acc), do: {:cont, %{acc | chunks: [acc.chunks, data]}}

  defp on_stream({:data, data}, acc) do
    case chunk(acc.conn, data) do
      {:ok, conn} ->
        {:cont, %{acc | conn: conn, chunks: [acc.chunks, data], sse_error: acc.sse_error || sse_error(data)}}

      {:error, _closed} ->
        # The client hung up mid-stream — an interrupt (Esc). Stop reading a
        # response nobody will see.
        {:halt, %{acc | aborted: true}}
    end
  end

  defp on_stream(_other, acc), do: {:cont, acc}

  # An SSE `error` event (overloaded_error, api_error) inside a 200 stream;
  # a chunk may split it, so only the event's own line is looked for.
  defp sse_error(data) do
    case :binary.match(data, "event: error") do
      :nomatch -> nil
      {at, _} -> data |> binary_part(at, min(300, byte_size(data) - at)) |> String.replace("\n", " ")
    end
  end

  defp finish_observe(nil, _acc), do: :ok

  defp finish_observe(observe, acc) do
    observe.(acc.status || 499, acc.headers, IO.iodata_to_binary(acc.chunks), acc.aborted)
  rescue
    e -> Logger.warning("[proxy] response observation failed: #{Exception.message(e)}")
  end

  # An error in the API's own shape, so Claude Code reports and retries it as
  # it would an upstream one.
  defp api_error(conn, status, type, message) do
    conn
    |> put_resp_content_type("application/json")
    |> no_transform()
    |> send_resp(status, Jason.encode!(%{type: "error", error: %{type: type, message: message}}))
  end

  # Claude Code sends `accept-encoding: gzip`, and Bandit would otherwise
  # compress what we relay — the SSE stream included, re-encoding the API's
  # bytes on their way through. `no-transform` is the standard way to say a
  # response must pass unaltered, and Bandit honours it.
  defp no_transform(conn) do
    case get_resp_header(conn, "cache-control") do
      [] -> put_resp_header(conn, "cache-control", "no-transform")
      [cc | _] -> if cc =~ "no-transform", do: conn, else: put_resp_header(conn, "cache-control", cc <> ", no-transform")
    end
  end
end
