defmodule ClaudiverseServerWeb.SubmissionController do
  @moduledoc """
  Component B's HTTP surface: a worker delivers a match without touching git.
  """
  use ClaudiverseServerWeb, :controller

  alias ClaudiverseServer.Submissions

  # POST /api/kb/submissions
  def create(conn, params) do
    case Submissions.submit(params) do
      {:ok, sub} ->
        json(conn, %{ok: true, submission: sub_json(sub), durable: true})

      {:error, cs} ->
        conn |> put_status(:unprocessable_entity) |> json(%{ok: false, errors: errors(cs)})
    end
  end

  # GET /api/kb/submissions/:id
  def show(conn, %{"id" => id}) do
    case Submissions.get(to_int(id)) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "no submission #{id}"})

      %{submission: sub, gates: gates, integration: int} ->
        json(conn, %{
          ok: true,
          submission: sub_json(sub),
          gates: Enum.map(gates, &gate_json/1),
          integration: int && int_json(int)
        })
    end
  end

  # GET /api/kb/submissions
  def index(conn, params) do
    opts =
      [:address, :build, :unit, :state, :submitted_by]
      |> Enum.map(&{&1, params[to_string(&1)]})
      |> Keyword.put(:limit, to_int(params["limit"] || 50))

    json(conn, %{ok: true, submissions: Submissions.list(opts) |> Enum.map(&sub_json/1)})
  end

  # POST /api/kb/submissions/:id/gates
  def gate(conn, %{"id" => id} = params) do
    case Submissions.record_gate(to_int(id), Map.drop(params, ["id"])) do
      {:ok, g} -> json(conn, %{ok: true, gate: gate_json(g)})
      {:error, :no_such_submission} -> conn |> put_status(:not_found) |> json(%{error: "no submission #{id}"})
      {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{ok: false, errors: errors(cs)})
    end
  end

  # POST /api/kb/submissions/:id/integrate
  def integrate(conn, %{"id" => id, "sha" => sha} = p) do
    case Submissions.integrate(to_int(id), sha, p["by"] || "integrator", force: p["force"] == true) do
      {:ok, int} ->
        json(conn, %{ok: true, integration: int_json(int)})

      {:error, why} when is_binary(why) ->
        # 409, not 422: the submission is well-formed, the WORLD moved. That
        # distinction is what tells a client to re-gate rather than to fix its
        # payload.
        conn |> put_status(:conflict) |> json(%{ok: false, error: why})

      {:error, other} ->
        conn |> put_status(:unprocessable_entity) |> json(%{ok: false, error: inspect(other)})
    end
  end

  # POST /api/kb/submissions/:id/revert
  def revert(conn, %{"id" => id} = p) do
    case Submissions.revert(to_int(id), p["reason"] || "") do
      {:ok, int} -> json(conn, %{ok: true, integration: int_json(int)})
      {:error, :not_integrated} -> conn |> put_status(:conflict) |> json(%{error: "not integrated"})
      {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{ok: false, errors: errors(cs)})
    end
  end

  @doc """
  GET /api/kb/submissions/blind-gates — gate runs whose positive control did
  not fire.

  ⭐ Component B's acceptance criterion names this query and requires the set to
  be EMPTY. A gate that has quietly lost its ability to fail reports PASS
  forever, and nothing else distinguishes it from one that works.
  """
  def blind_gates(conn, params) do
    gates = Submissions.gates_without_positive_control(limit: to_int(params["limit"] || 100))

    json(conn, %{
      ok: true,
      count: length(gates),
      gates: Enum.map(gates, &gate_json/1),
      note: "these gate runs recorded no positive control — they cannot be shown to have been able to fail"
    })
  end

  defp sub_json(s) do
    Map.take(s, [
      :id, :address, :unit, :build, :tier, :base_sha, :compiler, :flags,
      :body_hash, :notes, :submitted_by, :state, :superseded_by, :inserted_at
    ])
    |> Map.put(:has_body, not is_nil(s.body_c))
  end

  defp gate_json(g) do
    Map.take(g, [
      :id, :submission_id, :gate_name, :ran_at, :verdict, :raw_output,
      :positive_control_output, :runner, :environment
    ])
    |> Map.put(:could_have_failed, not blank?(g.positive_control_output))
  end

  defp int_json(i),
    do: Map.take(i, [:id, :submission_id, :integrated_sha, :integrated_at, :integrated_by, :reverted_at, :revert_reason])

  defp blank?(nil), do: true
  defp blank?(s), do: String.trim(s) == ""

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) do
    case Integer.parse(to_string(v)) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp errors(cs),
    do: Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
end
