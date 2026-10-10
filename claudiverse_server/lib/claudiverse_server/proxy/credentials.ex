defmodule ClaudiverseServer.Proxy.Credentials do
  @moduledoc """
  The Anthropic credential a pooled seat's requests go out with.

  A seat opts in by sending the placeholder `Bearer cv-pool` instead of a real
  token (`CLAUDE_CODE_OAUTH_TOKEN=cv-pool`). The proxy swaps in a token leased
  from the pool, so the seat never holds an Anthropic credential and none
  crosses the network to it.

  ## Why a cache, and why one

  `AnthropicAuths.lease/1` writes `last_leased_at` and may refresh a token over
  HTTP. Leasing per request would put SQLite on the path of every model call,
  so the current lease is held here and renewed only when it nears expiry,
  every `@relook_ms` (that is how seats move back to the preferred account once
  it recovers), or when the API rejects it.

  One lease serves every pooled seat: the pool hands out the best available
  account and there is only one best. Which seat uses which account is still
  recorded per seat, at the moment it changes.

  ## The in-flight guard

  When an account hits its limit, every request in flight on it comes back
  429 within moments of each other. Only the FIRST may cool the account; the
  rest find the lease has already moved on and simply retry on the new one.
  Reporting each of them was measured to cool the account just switched TO
  (2026-09-13: "Both accounts unavailable, fleet blocked"). The guard is the
  auth id each report names: a report about an account that is no longer the
  current lease is dropped.
  """
  use GenServer

  require Logger

  alias ClaudiverseServer.AnthropicAuths

  @placeholder "cv-pool"
  @relook_ms :timer.minutes(5)
  # Renew this long before the stored expiry, so a request never leaves with a
  # token that dies on the wire.
  @expiry_margin_s 120

  def placeholder, do: @placeholder

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The token to send for `seat`: `{:ok, lease}` or `{:error, reason}`."
  def current(seat), do: GenServer.call(__MODULE__, {:current, seat}, 30_000)

  @doc """
  `auth_id` answered 429. Cool it (once) and return the lease to retry with.
  `resets_at` is the API's own reset time, when it gave one.
  """
  def rate_limited(auth_id, resets_at, seat),
    do: GenServer.call(__MODULE__, {:rate_limited, auth_id, resets_at, seat}, 30_000)

  @doc "`auth_id` answered 401. Force one refresh (once) and return the lease to retry with."
  def unauthorized(auth_id, seat), do: GenServer.call(__MODULE__, {:unauthorized, auth_id, seat}, 30_000)

  @doc "Forget the cached lease (tests, and an operator re-enrolling an account)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- Server ---

  @impl true
  def init(_opts), do: {:ok, %{lease: nil, leased_at: 0, seats: %{}}}

  @impl true
  def handle_call({:current, seat}, _from, state) do
    state = if fresh?(state), do: {:ok, state}, else: relet(state, &AnthropicAuths.lease/0, seat, "proxy-lease")
    reply(state, seat)
  end

  def handle_call({:rate_limited, auth_id, resets_at, seat}, _from, state) do
    result =
      if current_auth?(state, auth_id) do
        Logger.info("[proxy] #{state.lease.label} rate limited (via #{seat}); failing over")
        relet(state, fn -> AnthropicAuths.report_rate_limited(state.lease.auth, resets_at, "rate limited (429 via proxy)") end, seat, "proxy-failover")
      else
        # Another request already failed this account over: in flight from the
        # old account, retry on the current one without a second report.
        current_or_lease(state, seat)
      end

    reply(result, seat)
  end

  def handle_call({:unauthorized, auth_id, seat}, _from, state) do
    result =
      if current_auth?(state, auth_id) do
        Logger.warning("[proxy] #{state.lease.label} answered 401 (via #{seat}); forcing a refresh")
        relet(state, fn -> AnthropicAuths.report_unauthorized(state.lease.auth) end, seat, "proxy-renewal")
      else
        current_or_lease(state, seat)
      end

    reply(result, seat)
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{lease: nil, leased_at: 0, seats: %{}}}

  # --- Helpers ---

  defp fresh?(%{lease: nil}), do: false

  defp fresh?(%{lease: lease, leased_at: at}) do
    now_ms() - at < @relook_ms and not expiring?(lease)
  end

  defp expiring?(%{expires_at: %DateTime{} = exp}), do: DateTime.diff(exp, DateTime.utc_now()) < @expiry_margin_s
  defp expiring?(_), do: false

  defp current_auth?(%{lease: %{auth_id: id}}, id), do: true
  defp current_auth?(_, _), do: false

  defp current_or_lease(state, seat) do
    if fresh?(state), do: {:ok, state}, else: relet(state, &AnthropicAuths.lease/0, seat, "proxy-lease")
  end

  defp relet(state, fun, seat, via) do
    case fun.() do
      {:ok, lease} ->
        {:ok, note_seat(%{state | lease: lease, leased_at: now_ms()}, seat, via)}

      {:error, reason} ->
        Logger.warning("[proxy] no pool credential: #{inspect(reason)}")
        {{:error, reason}, %{state | lease: nil, leased_at: 0}}
    end
  end

  # Record a seat's account when it changes, not on every request.
  defp note_seat(%{lease: %{auth_id: id}} = state, seat, via) when is_binary(seat) do
    if Map.get(state.seats, seat) == id do
      state
    else
      AnthropicAuths.record_assignment(%{title: seat}, id, via)
      %{state | seats: Map.put(state.seats, seat, id)}
    end
  end

  defp note_seat(state, _seat, _via), do: state

  defp reply({:ok, state}, seat) do
    state = note_seat(state, seat, "proxy-lease")
    {:reply, {:ok, Map.take(state.lease, [:auth_id, :label, :access_token])}, state}
  end

  defp reply({{:error, reason}, state}, _seat), do: {:reply, {:error, reason}, state}

  defp now_ms, do: System.monotonic_time(:millisecond)
end
