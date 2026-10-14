defmodule ClaudiverseServerWeb.AnthropicAuthController do
  @moduledoc """
  The account pool: seats lease tokens here, the panel enrols and inspects.

  Every route is behind the `:authenticated` pipeline, same as the rest of the
  API.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.AnthropicAuths
  alias ClaudiverseServer.AnthropicAuths.{AnthropicAuth, UsageHistory}

  # --- seat-facing ----------------------------------------------------------

  def lease(conn, params) do
    exclude = params |> Map.get("exclude_ids", []) |> List.wrap() |> Enum.map(&to_int/1)

    case AnthropicAuths.lease(exclude_ids: Enum.reject(exclude, &is_nil/1)) do
      {:ok, lease} ->
        # An exclude list means the caller is walking away from an account it
        # already had, i.e. a failover — a plain lease is a seat arriving. The
        # distinction is the only way to see a seat that keeps being bounced off
        # its preferred account, which reads as ordinary traffic otherwise.
        via = if exclude == [], do: "lease", else: "failover"
        record_seat(conn, lease, via)
        json(conn, render_lease(lease))

      {:error, :no_available_auth} ->
        # Report WHEN, not just THAT. "everything is rate-limited" with no
        # timestamp sends the operator hunting; with one it is a wait.
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "no_available_auth", next_available_at: earliest_cooldown()})

      {:error, reason} ->
        conn |> put_status(:bad_gateway) |> json(%{error: inspect(reason)})
    end
  end

  def rate_limited(conn, %{"id" => id} = params) do
    with %AnthropicAuth{} = auth <- AnthropicAuths.get_auth(id) do
      resets_at = parse_dt(params["resets_at"])

      case AnthropicAuths.report_rate_limited(auth, resets_at, params["reason"]) do
        {:ok, next} ->
          record_seat(conn, next, "failover")
          json(conn, %{cooled: auth.label, next: render_lease(next)})

        {:error, :no_available_auth} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{
            cooled: auth.label,
            error: "no_available_auth",
            next_available_at: earliest_cooldown()
          })

        {:error, reason} ->
          conn |> put_status(:bad_gateway) |> json(%{error: inspect(reason)})
      end
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "unknown auth"})
    end
  end

  def unauthorized(conn, %{"id" => id}) do
    with %AnthropicAuth{} = auth <- AnthropicAuths.get_auth(id) do
      case AnthropicAuths.report_unauthorized(auth) do
        {:ok, lease} ->
          json(conn, render_lease(lease))

        {:error, :needs_reauth} ->
          conn
          |> put_status(:conflict)
          |> json(%{error: "needs_reauth", label: auth.label})

        {:error, reason} ->
          conn |> put_status(:bad_gateway) |> json(%{error: inspect(reason)})
      end
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "unknown auth"})
    end
  end

  # --- panel-facing ---------------------------------------------------------

  def index(conn, _params) do
    json(conn, %{
      vault_configured: AnthropicAuths.vault_configured?(),
      auths: Enum.map(AnthropicAuths.list_auths(), &render_auth/1),
      # The account a lease gets right now. It differs from the preferred one
      # (lowest priority) while that one is cooling or needs re-auth.
      current_id: AnthropicAuths.current_id(),
      seats: Enum.map(AnthropicAuths.list_assignments(), &render_assignment/1)
    })
  end

  @doc """
  GET /api/anthropic_auths/usage_history?days=28&tz=Europe/Oslo&raw=1: each
  account's use of its weekly limit per local day (UsageHistory.report/4).
  Any token may read it, as `index`. `days` is 1..400 (default 28), `tz` an
  IANA zone (default the server's CV_USAGE_TZ, else Europe/Oslo), `raw=1` adds
  the samples. 400 on a bad `days` or `tz`.
  """
  def usage_history(conn, params) do
    tz = params["tz"] || UsageHistory.default_tz()

    case Integer.parse(params["days"] || "28") do
      {days, ""} when days in 1..400 ->
        if UsageHistory.valid_zone?(tz) do
          json(conn, UsageHistory.report(days, tz, params["raw"] in ["1", "true"]))
        else
          conn |> put_status(:bad_request) |> json(%{error: "tz must be an IANA time zone, e.g. Europe/Oslo"})
        end

      _ ->
        conn |> put_status(:bad_request) |> json(%{error: "days must be a whole number from 1 to 400"})
    end
  end

  @doc """
  Begin enrolment. Returns the URL to open plus the PKCE material the caller
  must hand back to `complete/2`.

  The verifier is returned to the panel rather than held server-side on purpose:
  it keeps enrolment stateless, and the verifier is worthless without the
  matching code, which only the operator's browser ever sees.
  """
  def authorize(conn, _params) do
    json(conn, AnthropicAuths.start_authorization())
  end

  # Without a priority, a new account gets 100 and a re-enrolled one keeps its
  # own (AnthropicAuths.store_enrolment/5).
  def complete(conn, %{"label" => label, "code" => code, "verifier" => verifier} = params) do
    conn
    |> enrolled(AnthropicAuths.complete_authorization(label, code, verifier, params["state"], %{priority: to_int(params["priority"])}))
  rescue
    e -> exchange_crashed(conn, e)
  end

  @doc """
  `POST /api/anthropic_auths/:id/reauthorize/complete` — re-authorize that
  account in one step, from a code begun at `POST /api/anthropic_auths/authorize`:
  `{code, verifier, state, force}`. The row keeps its id, label and priority
  (AnthropicAuths.reauthorize/5). A login whose email is not the row's is a 409
  naming both, and nothing is stored, unless `force` is true. App or super
  token: it replaces a credential the whole fleet leases.
  """
  def reauthorize(conn, %{"id" => id, "code" => code, "verifier" => verifier} = params) do
    cond do
      not ClaudiverseServer.Accounts.app_powers?(conn.assigns[:token_context]) ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden", detail: "re-authorizing an account is app-only"})

      auth = AnthropicAuths.get_auth(id) ->
        result = AnthropicAuths.reauthorize(auth, code, verifier, params["state"], force: params["force"] in [true, "true"])

        case result do
          {:error, {:account_mismatch, stored, signed_in}} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: "account_mismatch", stored_email: stored.email, signed_in_email: signed_in.email,
                      stored_account_uuid: stored.uuid, signed_in_account_uuid: signed_in.uuid,
                      detail: "#{auth.label} is #{who(stored)}, but this login is #{who(signed_in)}. Nothing was changed. " <>
                                "Sign in as #{who(stored)}, or send force=true to make #{auth.label} #{who(signed_in)}."})

          {:error, {:email_unknown, stored}} ->
            conn
            |> put_status(:conflict)
            |> json(%{error: "email_unknown", stored_email: stored.email, signed_in_email: nil,
                      stored_account_uuid: stored.uuid, signed_in_account_uuid: nil,
                      detail: "could not tell which account this login is, to check it is #{who(stored)}. Nothing was changed. " <>
                                "Send force=true to re-authorize #{auth.label} without the check."})

          other ->
            enrolled(conn, other)
        end

      true ->
        conn |> put_status(:not_found) |> json(%{error: "unknown auth"})
    end
  rescue
    e -> exchange_crashed(conn, e)
  end

  def reauthorize(conn, _params),
    do: conn |> put_status(:bad_request) |> json(%{error: "bad_request", detail: "code and verifier are required"})

  defp who(%{email: e}) when is_binary(e), do: e
  defp who(%{uuid: u}) when is_binary(u), do: "account #{u}"
  defp who(_), do: "an unknown account"

  defp enrolled(conn, result) do
    case result do
      {:ok, auth} ->
        json(conn, render_auth(auth))

      {:error, :state_mismatch} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "state_mismatch", detail: "the pasted code did not match this attempt"})

      {:error, {:http, status, _}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "exchange_failed", detail: "Anthropic returned HTTP #{status}"})

      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  # 🔴 An unhandled raise here reaches the panel as a bare HTTP 500 with no
  # body, which is the least useful thing a failing enrolment can do — the
  # operator is left with a dead form and nothing to act on. Report the reason.
  # (First production failure was :inets missing from the release; the message
  # said nothing at all.)
  defp exchange_crashed(conn, e) do
    require Logger
    Logger.error("anthropic_auths enrolment raised: #{Exception.message(e)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "exchange_crashed", detail: Exception.message(e)})
  end

  def refresh_usage(conn, %{"id" => id}) do
    with %AnthropicAuth{} = auth <- AnthropicAuths.get_auth(id) do
      case AnthropicAuths.refresh_usage(auth) do
        {:ok, updated} -> json(conn, render_auth(updated))
        {:error, reason} -> conn |> put_status(:bad_gateway) |> json(%{error: inspect(reason)})
      end
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "unknown auth"})
    end
  end

  @doc """
  `POST /api/anthropic_auths/:id/preferred` — that account ranks first (see
  AnthropicAuths.make_preferred/1). App or super token: it moves the whole
  fleet's usage, and every seat carries the shared api token.
  """
  def preferred(conn, %{"id" => id}) do
    cond do
      not ClaudiverseServer.Accounts.app_powers?(conn.assigns[:token_context]) ->
        conn |> put_status(:forbidden) |> json(%{error: "choosing the preferred account is app-only"})

      auth = AnthropicAuths.get_auth(id) ->
        {:ok, auths} = AnthropicAuths.make_preferred(auth, conn.assigns.current_user.email)
        json(conn, %{auths: Enum.map(auths, &render_auth/1), current_id: AnthropicAuths.current_id()})

      true ->
        conn |> put_status(:not_found) |> json(%{error: "unknown auth"})
    end
  end

  def delete(conn, %{"id" => id}) do
    with %AnthropicAuth{} = auth <- AnthropicAuths.get_auth(id) do
      {:ok, _} = AnthropicAuths.delete_auth(auth)
      json(conn, %{deleted: auth.label})
    else
      nil -> conn |> put_status(:not_found) |> json(%{error: "unknown auth"})
    end
  end

  # --- rendering ------------------------------------------------------------

  # 🔴 NEVER render access_token or refresh_token here. The panel has no use for
  # them and a listing endpoint is exactly where a credential leaks into a log,
  # a screenshot, or a browser cache. Only `lease` returns a token, and only the
  # one it just issued.
  defp render_auth(%AnthropicAuth{} = a) do
    %{
      id: a.id,
      label: a.label,
      account_email: a.account_email,
      account_uuid: a.account_uuid,
      status: effective_status(a),
      # Why it needs re-auth (e.g. "refresh rejected with HTTP 400"); null
      # otherwise. The same text is in cooldown_reason, where older clients read it.
      reauth_reason: if(a.status == "needs_reauth", do: a.cooldown_reason),
      cooldown_until: a.cooldown_until,
      cooldown_reason: a.cooldown_reason,
      priority: a.priority,
      # Visible in the panel because it decides what a leased session may do:
      # without user:profile, Remote Control and /code-review ultra refuse.
      scopes: a.scopes,
      token_valid: AnthropicAuth.token_valid?(a),
      expires_at: a.expires_at,
      last_refreshed_at: a.last_refreshed_at,
      last_leased_at: a.last_leased_at,
      usage: a.usage_snapshot,
      usage_checked_at: a.usage_checked_at
    }
  end

  # The stored `status` is a cache of `cooldown_until`. Render from the
  # timestamp so an elapsed cooldown reads as available even if no write has
  # happened since it expired — otherwise the panel shows an account as blocked
  # long after it recovered.
  defp effective_status(%AnthropicAuth{status: "needs_reauth"}), do: "needs_reauth"

  defp effective_status(%AnthropicAuth{} = a) do
    if AnthropicAuth.leasable?(a), do: "available", else: "cooling_down"
  end

  defp render_lease(lease) do
    %{
      auth_id: lease.auth_id,
      label: lease.label,
      access_token: lease.access_token,
      expires_at: lease.expires_at,
      # 🔑 THE TOKEN'S REAL SCOPES, and they matter more than they look.
      # A client that sets CLAUDE_CODE_OAUTH_TOKEN without also setting
      # CLAUDE_CODE_OAUTH_SCOPES gets upstream's conservative default of
      # ["user:inference"] (coreSchemas.js:34898 `x0/1`). Anything gated on
      # `scopes.includes("user:profile")` then refuses — Remote Control and
      # `/code-review ultra` among them — even though the token DOES carry that
      # scope, because we request org:create_api_key + user:profile +
      # user:inference at authorize time.
      # Passing them through is the sanctioned path, not a workaround: upstream
      # populates the same variable from a credential's scopes at
      # utils/managedEnvConstants.js:7125.
      scopes: lease.scopes
    }
  end

  defp earliest_cooldown do
    AnthropicAuths.list_auths()
    |> Enum.reject(&(&1.status == "needs_reauth"))
    |> Enum.map(& &1.cooldown_until)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      list -> Enum.min_by(list, &DateTime.to_unix/1)
    end
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(v) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_dt(v) when is_integer(v), do: DateTime.from_unix!(v) |> DateTime.truncate(:second)
  defp parse_dt(_), do: nil

  defp to_int(nil), do: nil
  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp to_int(_), do: nil

  # Bookkeeping only — see AnthropicAuths.record_assignment/3. Deliberately
  # ignores its own result: this hangs off the path every seat uses to obtain
  # credentials, and must never be able to turn a successful lease into an error.
  defp record_seat(conn, %{auth_id: auth_id}, via) do
    AnthropicAuths.record_assignment(
      conn.assigns[:client_identity] || %{title: nil, claude_session_id: nil},
      auth_id,
      via
    )
  end

  defp record_seat(_conn, _lease, _via), do: :ok

  defp render_assignment(a) do
    %{
      title: a.title,
      claude_session_id: a.claude_session_id,
      auth_id: a.anthropic_auth_id,
      # Denormalised on purpose: "ipsum-admin -> Work" is the readable answer, and a
      # caller should not have to join it back against the auths list by hand.
      label: a.anthropic_auth && a.anthropic_auth.label,
      assigned_at: a.assigned_at,
      via: a.via
    }
  end
end
