defmodule ClaudiverseServer.JoinCodes do
  @moduledoc """
  One-time join codes: how a new machine gets its tokens without anyone
  pasting one.

  The web panel's (or an app's) "Add a machine" mints a code with an app or
  super token (`mint/3`), and shows it inside the one-line installer command.
  The installer redeems it (`redeem/3`, no token: the code is the credential)
  for the machine's seat token and host token, the same pair
  `Accounts.connect_machine/2` mints. So no long-lived token is ever typed,
  pasted, put on a command line or kept in a shell's history: the code is
  worth nothing once used or after `ttl_s` (15 minutes).

  A code is 8 characters from an alphabet with no look-alikes (no 0/O, 1/I/L,
  U), shown as `XXXX-XXXX`: 30^8, about 6.6e11. Only its sha256 is stored. A
  redeem is single-use by a conditional update (`used_at IS NULL AND
  expires_at > now`), so two installers racing with one code cannot both get
  tokens, and the controller throttles failed redeems per address.
  """
  import Ecto.Query

  alias ClaudiverseServer.{Accounts, Repo}
  alias ClaudiverseServer.JoinCodes.JoinCode

  @alphabet ~c"ABCDEFGHJKMNPQRSTVWXYZ23456789"
  @ttl_s 15 * 60
  @name ~r/\A[A-Za-z0-9._-]{1,128}\z/

  def ttl_s, do: Application.get_env(:claudiverse_server, __MODULE__, [])[:ttl_s] || @ttl_s

  @doc """
  A new code for `user`, for the machine `machine` (nil: the machine names
  itself when it joins). `{:ok, code, %JoinCode{}}` or `{:error, :bad_machine_name}`.
  """
  def mint(user, machine, now \\ DateTime.utc_now()) do
    if machine == nil or Regex.match?(@name, machine) do
      code = for(_ <- 1..8, into: "", do: <<Enum.random(@alphabet)>>)
      code = String.slice(code, 0, 4) <> "-" <> String.slice(code, 4, 4)

      row =
        Repo.insert!(%JoinCode{
          user_id: user.id,
          code_hash: hash(code),
          machine: machine,
          expires_at: now |> DateTime.add(ttl_s(), :second) |> DateTime.truncate(:second)
        })

      {:ok, code, row}
    else
      {:error, :bad_machine_name}
    end
  end

  @doc """
  Redeem `code` for the machine `machine` (the name the installer offers; the
  code's own name wins when it was minted with one). `{:ok, %{machine,
  seat_token, host_token}}`, or `{:error, :invalid}` for a code that is
  unknown, used or expired (one answer for all three: a guesser learns
  nothing), or `{:error, :bad_machine_name}`.
  """
  def redeem(code, machine, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    # A code that is unknown, used or expired is :invalid whatever else is
    # wrong, so only a live code's holder hears about the machine name.
    with %JoinCode{used_at: nil} = row <- Repo.get_by(JoinCode, code_hash: hash(code)),
         true <- DateTime.compare(row.expires_at, now) == :gt,
         {:ok, name} <- machine_name(row.machine || machine),
         {1, _} <-
           from(j in JoinCode, where: j.id == ^row.id and is_nil(j.used_at) and j.expires_at > ^now)
           |> Repo.update_all(set: [used_at: now, used_by_machine: name, updated_at: now]),
         %{} = user <- Repo.get(Accounts.User, row.user_id),
         {:ok, tokens} <- Accounts.connect_machine(user, name) do
      {:ok, Map.put(tokens, :machine, name)}
    else
      {:error, reason} when reason in [:bad_machine_name, :machine_required] -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end

  defp machine_name(nil), do: {:error, :machine_required}
  defp machine_name(name), do: if(Regex.match?(@name, name), do: {:ok, name}, else: {:error, :bad_machine_name})

  # Case, spaces and dashes are the reader's, not the code's.
  defp hash(code) when is_binary(code) do
    normal = code |> String.upcase() |> String.replace(~r/[\s-]/, "")
    :crypto.hash(:sha256, normal) |> Base.encode16(case: :lower)
  end

  defp hash(_), do: ""
end
