defmodule ClaudiverseServer.AnthropicAuths.Vault do
  @moduledoc """
  AES-256-GCM for the stored OAuth tokens.

  Uses Erlang's `:crypto` directly rather than pulling in Cloak — this needs one
  cipher and one key, and a dependency would be more surface than the problem.
  GCM rather than CBC because it authenticates: a tampered ciphertext fails to
  decrypt instead of yielding plausible garbage that gets sent to Anthropic as a
  bearer token.

  ## What this protects, stated honestly

  It keeps live tokens out of casual `psql`/`sqlite3` output, logs, and database
  backups. It is NOT a defence against a compromised host: the key lives in the
  environment of the same process that holds the database.

  ## Key

      CV_VAULT_KEY   base64 of exactly 32 random bytes
      mix run -e 'IO.puts Base.encode64(:crypto.strong_rand_bytes(32))'

  🔴 A MISSING KEY MAKES THE FEATURE UNAVAILABLE, LOUDLY — it never degrades to
  storing plaintext. Silent plaintext is the worst outcome available: the panel
  would look identical and nothing would ever tell you. The failure is scoped to
  this module, so the rest of claudiverse (forum, sessions, tasks) keeps working
  with the pool simply unconfigured.
  """

  @aad "anthropic_auths.v1"
  @iv_bytes 12
  @tag_bytes 16

  @doc "Encrypt a plaintext token. Raises if no key is configured."
  def encrypt(nil), do: nil

  def encrypt(plaintext) when is_binary(plaintext) do
    key = key!()
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ct, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, @tag_bytes, true)

    # iv || tag || ciphertext — both prefixes are fixed width, so decrypt can
    # split without a length header or any format negotiation.
    iv <> tag <> ct
  end

  @doc """
  Decrypt. Returns nil on any failure rather than raising.

  ⚠️ Deliberate: a token that cannot be decrypted (wrong key, tampered row,
  a value written before the key was rotated) must read as "no usable token" so
  the caller re-authenticates. Raising here would take down a lease request over
  one bad row, and returning the ciphertext would send it to Anthropic as a
  bearer token and produce a 401 that looks like an expired session.
  """
  def decrypt(nil), do: nil

  def decrypt(<<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ct::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key!(), iv, ct, @aad, tag, false) do
      :error -> nil
      plaintext -> plaintext
    end
  rescue
    _ -> nil
  end

  def decrypt(_malformed), do: nil

  @doc "Is a usable key configured? Lets callers report the cause instead of 500ing."
  def configured? do
    match?({:ok, _}, fetch_key())
  end

  defp key! do
    case fetch_key() do
      {:ok, key} ->
        key

      {:error, reason} ->
        raise """
        AnthropicAuths vault key is #{reason}.

        Set CV_VAULT_KEY to base64 of 32 random bytes:
            mix run -e 'IO.puts Base.encode64(:crypto.strong_rand_bytes(32))'

        Refusing to store or read credentials without it. This never falls back
        to plaintext — a silent downgrade would be invisible in the panel.
        """
    end
  end

  defp fetch_key do
    case System.get_env("CV_VAULT_KEY") do
      nil ->
        {:error, "not set (CV_VAULT_KEY)"}

      raw ->
        case Base.decode64(String.trim(raw)) do
          {:ok, key} when byte_size(key) == 32 -> {:ok, key}
          {:ok, key} -> {:error, "#{byte_size(key)} bytes after base64 decode, needs exactly 32"}
          :error -> {:error, "not valid base64"}
        end
    end
  end
end
