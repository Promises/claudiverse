defmodule ClaudiverseServer.Fixtures do
  alias ClaudiverseServer.{Accounts, Sessions}

  def user_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user#{unique}@test.com",
        password: "password123456"
      })
      |> Accounts.register_user()

    user
  end

  def user_with_token(attrs \\ %{}) do
    user = user_fixture(attrs)
    token = Accounts.create_user_api_token(user)
    {user, token}
  end

  def session_fixture(user, attrs \\ %{}) do
    {:ok, session} =
      attrs
      |> Enum.into(%{
        title: "Test Session",
        type: :sidecar,
        mode: :json,
        status: :running,
        user_id: user.id
      })
      |> Sessions.create_session()

    session
  end
end
