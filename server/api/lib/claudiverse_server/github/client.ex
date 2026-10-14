defmodule ClaudiverseServer.GitHub.Client do
  @moduledoc """
  GitHub's REST API, read-only, with one token. The base URL is
  `:github_api_url` (https://api.github.com), so tests serve fixtures from a
  local plug: no test calls GitHub.

  Nothing here logs a request or its headers: the token is in them.

  🔴 READ-ONLY. `request/4` refuses every method but GET: a classic token can
  write to every repository its account can, and nothing here ever should.
  """

  @finch ClaudiverseServer.GitHub.Finch
  @timeout 15_000

  @doc """
  GET `path` (or a full URL GitHub gave, such as a Link header's next page).
  {:ok, %{status, headers (lowercase names), body (decoded JSON, or nil)}} or
  {:error, reason}.
  """
  def get(token, path, headers \\ []), do: request(:get, token, path, headers)

  @doc "The one way to GitHub. Any method but GET is refused, before anything is sent: {:error, :read_only}."
  def request(method, token, path, headers \\ [])

  def request(method, _token, _path, _headers) when method != :get, do: {:error, :read_only}

  def request(:get, token, path, headers) do
    url = if String.starts_with?(path, "http"), do: path, else: base_url() <> path

    req =
      Finch.build(:get, url, [
        {"authorization", "Bearer " <> token},
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"},
        {"user-agent", "claudiverse"}
        | headers
      ])

    case Finch.request(req, @finch, receive_timeout: @timeout) do
      {:ok, %Finch.Response{status: status, headers: hs, body: body}} ->
        {:ok, %{status: status, headers: Map.new(hs, fn {k, v} -> {String.downcase(k), v} end), body: decode(body)}}

      {:error, e} ->
        {:error, Exception.message(e)}
    end
  end

  defp decode(""), do: nil

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, v} -> v
      _ -> nil
    end
  end

  defp base_url, do: Application.get_env(:claudiverse_server, :github_api_url, "https://api.github.com")

  @doc "The next page's URL from a Link header, or nil."
  def next_page(%{headers: %{"link" => link}}) do
    case Regex.run(~r/<([^>]+)>;\s*rel="next"/, link) do
      [_, url] -> url
      _ -> nil
    end
  end

  def next_page(_), do: nil
end
