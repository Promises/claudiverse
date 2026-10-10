defmodule ClaudiverseServer.AnthropicAuths.OAuth do
  @moduledoc """
  Anthropic's OAuth endpoints — authorize URL, code exchange, refresh, usage.

  Values cross-checked against two independent sources, which is why they are
  trusted here: Claude Code's own `constants/oauth.js` in the deobfuscated tree,
  and `trickv/hass-claude-usage`, a working Home Assistant integration that
  authenticates against Anthropic with this exact paste-the-code flow.

  ⚠️ TOKEN_URL is on console.anthropic.com, NOT api.anthropic.com. The usage
  endpoint IS on api.anthropic.com. They are different hosts and it is an easy
  thing to get subtly wrong.
  """

  require Logger

  # 🔴 THESE ARE THE PROD VALUES, from the `zTu` block at constants/oauth.js:159.
  #
  # The first version of this file used the LOCAL DEV block (`te_`, :63) by
  # mistake — its CLIENT_ID is 22422756-… and its hosts are localhost-derived.
  # Anthropic rejected it outright with "OAuth Request Failed: Invalid client id
  # provided". Two blocks, near-identical shape, and the wrong one fails only at
  # the very last step of a human flow.
  #
  # ⚠️ THE DOMAINS MOVED, which is why third-party references disagree:
  #     console.anthropic.com  ->  platform.claude.com
  #     claude.ai/oauth/…      ->  claude.com/cai/oauth/…  (301s to claude.ai)
  # hass-claude-usage still carries the old console.anthropic.com URLs. They
  # apparently still redirect, which is exactly the kind of thing that works
  # until it doesn't.
  #
  # VERIFIED 2026-09-11 by opening the built URL in a real browser: it reaches
  # the Anthropic login screen with the OAuth params preserved in returnTo, no
  # "invalid client" error.
  @authorize_url "https://claude.com/cai/oauth/authorize"
  @token_url "https://platform.claude.com/v1/oauth/token"
  @redirect_uri "https://platform.claude.com/oauth/code/callback"
  @usage_url "https://api.anthropic.com/api/oauth/usage"
  @profile_url "https://api.anthropic.com/api/oauth/profile"
  @beta_header "oauth-2025-04-20"

  # ⚠️ CORRECTION: this is the SAME client id hass-claude-usage uses. An earlier
  # comment here claimed theirs was a different, narrower client — that was
  # wrong, and it came from comparing their value against the LOCAL dev id
  # rather than the prod one. There is one Claude Code OAuth client.
  @client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

  # 🔴 THE FULL SET Claude Code itself requests, from constants/oauth.js:26-32:
  #     s  = "org:create_api_key"
  #     Z5 = [user:profile, user:inference, user:sessions:claude_code,
  #           user:mcp_servers, user:file_upload]     (CLAUDE_AI_OAUTH_SCOPES)
  #     ALL = dedupe([s, user:profile] ++ Z5)
  #
  # ⚠️ The first version asked for only "org:create_api_key user:profile
  # user:inference" — a guess, not a reading — and Anthropic granted
  # "user:inference user:profile". That is enough for inference and for the
  # local user:profile gate, so a leased session LOOKS fully working; it fails
  # only at features needing the scopes we never asked for. MEASURED:
  # /remote-control cleared the local scope check and was then REJECTED at the
  # bridge handshake ("Claude.ai login was rejected"), which is what a
  # missing user:sessions:claude_code looks like from outside.
  #
  # Ask for what the client asks for. Anthropic grants a subset anyway, so
  # over-asking costs nothing and under-asking is invisible until a feature
  # refuses months later.
  @scopes "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

  def client_id, do: @client_id
  def redirect_uri, do: @redirect_uri
  def beta_header, do: @beta_header

  @doc """
  Start a paste-the-code flow. Returns the URL to open plus the PKCE verifier
  and state, which the caller must keep to complete the exchange.
  """
  def start_authorization do
    verifier = random_urlsafe(64)

    challenge =
      :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    state = random_urlsafe(32)

    query =
      URI.encode_query(%{
        "code" => "true",
        "client_id" => @client_id,
        "response_type" => "code",
        "redirect_uri" => @redirect_uri,
        "scope" => @scopes,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => state
      })

    %{url: "#{@authorize_url}?#{query}", verifier: verifier, state: state}
  end

  @doc """
  Exchange a pasted authorization code for tokens.

  🔑 THE PASTED CODE ARRIVES AS `code#state`. Anthropic's callback page shows
  both joined by a `#`, and people paste the whole thing. Splitting is not
  optional — sending the joined value as `code` fails with an opaque error that
  looks like a bad client configuration. Learned from the hass-claude-usage
  implementation, which does exactly this.
  """
  def exchange_code(pasted, verifier, expected_state) do
    {code, state} =
      case String.split(String.trim(pasted), "#", parts: 2) do
        [c, s] -> {c, s}
        [c] -> {c, ""}
      end

    # Only compare when the paste actually carried a state — a bare code is a
    # legitimate paste, and rejecting it would be a check that fires on correct
    # input.
    if state != "" and expected_state not in [nil, ""] and state != expected_state do
      {:error, :state_mismatch}
    else
      post_token(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "state" => state,
        "client_id" => @client_id,
        "redirect_uri" => @redirect_uri,
        "code_verifier" => verifier
      })
    end
  end

  @doc """
  Refresh an access token.

  ⚠️ The response MAY OR MAY NOT carry a new refresh token. Callers must keep
  the existing one when it is absent — see `AnthropicAuths.apply_refresh/2`.
  Overwriting with nil would destroy the only way back into the account.
  """
  def refresh(refresh_token) do
    post_token(%{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => @client_id
    })
  end

  @doc """
  Current usage for an account: session and weekly percentages, reset times, a
  weekly pace, per-model breakdown, extra-usage state.

  This is what makes routing proactive. Without it the only way to discover a
  limit is to take a 429 on a real request, which burns that turn.

  ⚠️ UNVERIFIED whether a token minted with Claude Code's client id is accepted
  here — the reference implementation uses a different client with
  `user:profile`. Callers must treat failure as "no usage data" and fall back to
  reactive 429 handling, never as "the account is fine".
  """
  def usage(access_token), do: authed_get(@usage_url, access_token)

  def profile(access_token), do: authed_get(@profile_url, access_token)

  # --- internals ---

  defp post_token(payload) do
    request(:post, @token_url, [{~c"content-type", ~c"application/json"}], Jason.encode!(payload))
  end

  defp authed_get(url, access_token) do
    request(
      :get,
      url,
      [
        {~c"authorization", ~c"Bearer #{access_token}"},
        {~c"anthropic-beta", ~c"#{@beta_header}"}
      ],
      nil
    )
  end

  defp request(method, url, headers, body) do
    # These are declared in mix.exs extra_applications so a RELEASE includes
    # them; starting them here too is belt-and-braces for escript/dev paths.
    # ⚠️ If :inets is missing from the release, this raises UndefinedFunctionError
    # and the caller sees a bare 500 with no clue why — which is exactly what
    # happened on the first production enrolment. The rescue below converts that
    # into a named error instead.
    :inets.start()
    :ssl.start()

    req =
      case method do
        :get -> {String.to_charlist(url), headers}
        :post -> {String.to_charlist(url), headers, ~c"application/json", body}
      end

    case :httpc.request(method, req, [{:timeout, 15_000}, {:connect_timeout, 10_000}], []) do
      {:ok, {{_, status, _}, _headers, resp}} when status in 200..299 ->
        Jason.decode(to_string(resp))

      {:ok, {{_, status, _}, _headers, resp}} ->
        # Log the status but NOT the body — it can echo token material.
        Logger.warning("AnthropicAuths.OAuth #{method} #{url} -> HTTP #{status}")
        {:error, {:http, status, to_string(resp)}}

      {:error, reason} ->
        Logger.warning("AnthropicAuths.OAuth #{method} #{url} failed: #{inspect(reason)}")
        {:error, {:transport, reason}}
    end
  rescue
    e in UndefinedFunctionError ->
      # Almost always :inets/:ssl missing from the release. Name the cause
      # rather than letting it surface as an unexplained 500.
      Logger.error("AnthropicAuths.OAuth: HTTP stack unavailable — #{Exception.message(e)}")
      {:error, {:http_stack_unavailable, Exception.message(e)}}

    e ->
      Logger.error("AnthropicAuths.OAuth #{method} #{url} raised: #{Exception.message(e)}")
      {:error, {:exception, Exception.message(e)}}
  end

  defp random_urlsafe(bytes) do
    :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
  end
end
