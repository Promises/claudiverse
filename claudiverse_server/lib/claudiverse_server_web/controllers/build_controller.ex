defmodule ClaudiverseServerWeb.BuildController do
  @moduledoc "Component D — periodic full builds and the blast radius they bound."
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.Builds

  def create(conn, params) do
    case Builds.record(params) do
      {:ok, b} ->
        # When a build goes red, answer the only question that matters next.
        suspects = if b.verdict == "FAIL", do: describe_suspects(), else: nil
        json(conn, %{ok: true, build: build_json(b), suspects: suspects})

      {:error, cs} ->
        conn |> put_status(:unprocessable_entity) |> json(%{ok: false, errors: errors(cs)})
    end
  end

  def index(conn, params) do
    json(conn, %{
      ok: true,
      builds: Builds.list(limit: to_int(params["limit"] || 20)) |> Enum.map(&build_json/1),
      last_green: Builds.last_green() |> then(&(&1 && build_json(&1)))
    })
  end

  @doc "Should a full build run now? Integration threshold OR elapsed time."
  def due(conn, params) do
    {due, why} =
      Builds.due?(
        every: to_int(params["every"] || 10),
        hours: to_int(params["hours"] || 24)
      )

    json(conn, %{ok: true, due: due, reason: why})
  end

  def suspects(conn, _params), do: json(conn, %{ok: true, suspects: describe_suspects()})

  defp describe_suspects do
    case Builds.suspects() do
      {:unbounded, n} ->
        %{
          bounded: false,
          integration_count: n,
          note:
            "no green build has ever been recorded, so NOTHING bounds the suspect set. " <>
              "All #{n} integrations are candidates — this is not a short list, and saying otherwise would mislead."
        }

      {:bounded, %{since_sha: sha, since: at, integrations: ints}} ->
        %{
          bounded: true,
          since_sha: sha,
          since: at,
          count: length(ints),
          integrations:
            Enum.map(ints, &Map.take(&1, [:id, :submission_id, :integrated_sha, :integrated_at, :integrated_by])),
          note: "newest first — the most recent is both most likely and cheapest to revert"
        }
    end
  end

  defp build_json(b) do
    Map.take(b, [
      :id, :sha, :fleet, :region, :verdict, :started_at, :finished_at,
      :differing_bytes, :elf_bytes, :undefined_symbols, :integrations_since,
      :runner, :environment
    ])
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) do
    case Integer.parse(to_string(v)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp errors(cs),
    do:
      Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
      end)
end
