defmodule ClaudiverseServer.AnthropicAuths.AnthropicAuth do
  @moduledoc """
  One Anthropic subscription account in the shared pool.

  Named AnthropicAuth rather than Account because `ClaudiverseServer.Accounts`
  is Phoenix web-panel login and means something else entirely.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias ClaudiverseServer.AnthropicAuths.Vault

  @statuses ~w(available cooling_down needs_reauth)

  schema "anthropic_auths" do
    field :label, :string
    field :account_email, :string
    # The account's stable id, from the token response (`account.uuid`).
    field :account_uuid, :string

    # Encrypted at rest. The changeset encrypts on write; read them back with
    # `decrypt_access_token/1` and `decrypt_refresh_token/1` rather than
    # touching the fields directly, so no call site can accidentally hand a
    # ciphertext to an HTTP client and get an opaque 401.
    field :access_token, :binary
    field :refresh_token, :binary

    field :expires_at, :utc_datetime
    field :scopes, :string

    field :status, :string, default: "available"
    field :cooldown_until, :utc_datetime
    field :cooldown_reason, :string

    field :priority, :integer, default: 100
    field :last_refreshed_at, :utc_datetime
    field :last_leased_at, :utc_datetime

    field :usage_snapshot, :map
    field :usage_checked_at, :utc_datetime

    timestamps()
  end

  def statuses, do: @statuses

  @doc """
  Create or update an auth. Plaintext tokens go in as `:access_token` /
  `:refresh_token` and are encrypted here.
  """
  def changeset(auth, attrs) do
    auth
    |> cast(attrs, [
      :label,
      :account_email,
      :account_uuid,
      :expires_at,
      :scopes,
      :status,
      :cooldown_until,
      :cooldown_reason,
      :priority,
      :last_refreshed_at,
      :last_leased_at,
      :usage_snapshot,
      :usage_checked_at
    ])
    |> validate_required([:label])
    |> validate_inclusion(:status, @statuses)
    |> put_encrypted(attrs, :access_token)
    |> put_encrypted(attrs, :refresh_token)
    |> enforce_cooldown_pairing()
    |> unique_constraint(:label)
  end

  # 🔴 THE INVARIANT THAT KEEPS `status` HONEST.
  # `cooldown_until` is authoritative and `status` is a cache of it. If a write
  # could set one without the other, the cached value would drift and the panel
  # would confidently report a stale state — the exact failure mode of a stored
  # status that nothing re-checks. So: cooling_down REQUIRES a timestamp, and
  # leaving cooling_down CLEARS it. Enforced here rather than trusted to call
  # sites, because there will eventually be a call site that forgets.
  defp enforce_cooldown_pairing(changeset) do
    case get_field(changeset, :status) do
      "cooling_down" ->
        if get_field(changeset, :cooldown_until) do
          changeset
        else
          add_error(changeset, :cooldown_until, "is required when status is cooling_down")
        end

      _ ->
        put_change(changeset, :cooldown_until, nil)
    end
  end

  defp put_encrypted(changeset, attrs, field) do
    case fetch_plain(attrs, field) do
      :error -> changeset
      {:ok, nil} -> put_change(changeset, field, nil)
      {:ok, value} -> put_change(changeset, field, Vault.encrypt(value))
    end
  end

  defp fetch_plain(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, v} -> {:ok, v}
      :error -> Map.fetch(attrs, Atom.to_string(field))
    end
  end

  def decrypt_access_token(%__MODULE__{access_token: nil}), do: nil
  def decrypt_access_token(%__MODULE__{access_token: ct}), do: Vault.decrypt(ct)

  def decrypt_refresh_token(%__MODULE__{refresh_token: nil}), do: nil
  def decrypt_refresh_token(%__MODULE__{refresh_token: ct}), do: Vault.decrypt(ct)

  @doc """
  Is this access token usable right now?

  The 60-second skew is deliberate: a token that expires in two seconds is not
  worth handing out, because the seat will 401 on its first request and we will
  have spent a lease to learn nothing.
  """
  def token_valid?(%__MODULE__{access_token: nil}), do: false
  def token_valid?(%__MODULE__{expires_at: nil}), do: false

  def token_valid?(%__MODULE__{expires_at: exp}) do
    DateTime.compare(exp, DateTime.add(DateTime.utc_now(), 60, :second)) == :gt
  end

  @doc """
  Usable for a lease? Reads the TIMESTAMP, never the cached `status` string.
  """
  def leasable?(%__MODULE__{status: "needs_reauth"}), do: false
  def leasable?(%__MODULE__{cooldown_until: nil}), do: true

  def leasable?(%__MODULE__{cooldown_until: until}) do
    DateTime.compare(DateTime.utc_now(), until) == :gt
  end
end
