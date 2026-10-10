defmodule ClaudiverseServer.Tasks.TaskDep do
  @moduledoc """
  A dependency edge. "#22445 blocks the landing" becomes a row rather than a
  sentence in another task's body — and a sentence in a body is what redirected
  a worker away from the task its runner was tracking.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(BLOCKS INFORMS)
  def kinds, do: @kinds

  schema "task_deps" do
    field :task_id, :id
    field :depends_on_task_id, :id
    field :kind, :string, default: "BLOCKS"
    timestamps()
  end

  def changeset(dep, attrs) do
    dep
    |> cast(attrs, [:task_id, :depends_on_task_id, :kind])
    |> validate_required([:task_id, :depends_on_task_id, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> no_self_dep()
    |> unique_constraint([:task_id, :depends_on_task_id])
  end

  defp no_self_dep(cs) do
    if get_field(cs, :task_id) == get_field(cs, :depends_on_task_id) do
      add_error(cs, :depends_on_task_id, "a task cannot depend on itself")
    else
      cs
    end
  end
end
