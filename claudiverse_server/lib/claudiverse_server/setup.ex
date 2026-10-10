defmodule ClaudiverseServer.Setup do
  @moduledoc """
  First-run sign-up: the first account is created in the web panel with a
  one-time setup code, instead of a command in the server's container.

  While the users table is EMPTY the server holds a setup code, 160 random
  bits shown as eight groups of four (`ABCD-EFGH-…`), and logs it at boot.
  A new code is made at every boot until someone signs up, so the newest one
  in `docker compose logs server` is always the valid one.

  `sign_up/2` creates the first user only when no user exists and the code
  matches (constant-time). Then sign-up is closed for good: the code is
  dropped, and every later call is refused, with or without the old code,
  because the check is the users table itself, not this process's state.
  An account created any other way (`mix claudiverse.register`,
  `Release.create_user/2`) closes it the same way.

  Calls are serialised here, so two sign-ups racing on an empty server cannot
  both pass the "no users yet" check.

  Later accounts are not open sign-up; there is no path for them here.

  Config: `config :claudiverse_server, ClaudiverseServer.Setup, at_boot: false`
  skips the boot code (set in test, which makes its codes with `issue/0`).
  """
  use GenServer
  require Logger

  import Ecto.Query

  alias ClaudiverseServer.{Accounts, Repo}
  alias ClaudiverseServer.Accounts.User

  @bytes 20

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Does this server still need its first account?"
  def needed?, do: not Repo.exists?(from(u in User))

  @doc """
  A fresh setup code, replacing any earlier one: `{:ok, code}`, or
  `{:error, :closed}` once an account exists. Boot calls it; so may an
  operator who lost the logged one (`bin/claudiverse_server rpc`).
  """
  def issue, do: GenServer.call(__MODULE__, :issue)

  @doc """
  Create the first account: `attrs` as for `Accounts.register_user/1`.
  `{:ok, user}`, `{:error, :closed}` (an account exists),
  `{:error, :bad_code}` or `{:error, changeset}` (the code stays valid).
  """
  def sign_up(code, attrs) when is_binary(code), do: GenServer.call(__MODULE__, {:sign_up, code, attrs})

  @impl true
  def init(nil) do
    if Keyword.get(Application.get_env(:claudiverse_server, __MODULE__, []), :at_boot, true),
      do: {:ok, nil, {:continue, :announce}},
      else: {:ok, nil}
  end

  @impl true
  def handle_continue(:announce, nil) do
    case open_code() do
      {:ok, code} ->
        Logger.warning("""

        ================================================================
          No account exists yet. Create the first one in the web panel
          with this one-time setup code:

              #{code}

          A restart makes a new code; the newest one logged is valid.
        ================================================================
        """)

        {:noreply, code}

      {:error, :closed} ->
        {:noreply, nil}
    end
  end

  @impl true
  def handle_call(:issue, _from, _code) do
    case open_code() do
      {:ok, code} -> {:reply, {:ok, code}, code}
      {:error, :closed} -> {:reply, {:error, :closed}, nil}
    end
  end

  def handle_call({:sign_up, given, attrs}, _from, code) do
    cond do
      not needed?() ->
        {:reply, {:error, :closed}, nil}

      is_nil(code) or not Plug.Crypto.secure_compare(normalize(given), normalize(code)) ->
        {:reply, {:error, :bad_code}, code}

      true ->
        case Accounts.register_user(attrs) do
          {:ok, user} -> {:reply, {:ok, user}, nil}
          {:error, changeset} -> {:reply, {:error, changeset}, code}
        end
    end
  end

  defp open_code do
    if needed?(), do: {:ok, generate()}, else: {:error, :closed}
  end

  defp generate do
    :crypto.strong_rand_bytes(@bytes)
    |> Base.encode32(padding: false)
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  # Pasted codes may lose or gain dashes, spaces and case.
  defp normalize(code), do: code |> String.upcase() |> String.replace(~r/[^A-Z2-7]/, "")
end
