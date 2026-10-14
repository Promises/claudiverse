defmodule ClaudiverseServer.Profiles.Profile do
  @moduledoc """
  A managed seat's settings (docs/design/seat-profiles.md). `name` is the seat
  title and tmux session; an edit cannot change it, only a rename
  (Profiles.rename/4) can; `revision` is bumped on every edit. Free-form arguments, environment variables, binary paths and
  MCP commands are deliberately absent: `runtime` and `mcp` are NAMES the
  machine's agent maps to its own binaries and catalog.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @name ~r/\A[A-Za-z0-9._-]{1,64}\z/
  # Runtime names as the agents' configs spell them ("stock+mod").
  @runtime ~r/\A[A-Za-z0-9.+_-]{1,64}\z/
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @roles ~w(member watcher orchestrator)
  @modes ~w(default acceptEdits plan auto)
  @efforts ~w(low medium high xhigh max)

  @editable ~w(machine folder fleet role can_notify runtime model effort permission_mode mcp pooled autostart resume debug protected)a

  schema "profiles" do
    field :name, :string
    field :revision, :integer, default: 1
    field :machine, :string
    field :folder, :string
    field :fleet, :string
    field :role, :string, default: "member"
    field :can_notify, :boolean, default: false
    field :runtime, :string, default: "stock+mod"
    field :model, :string
    field :effort, :string
    # A new profile runs in auto mode unless it says otherwise (operator
    # 2026-10-12: "default should be auto"); the column default agrees.
    field :permission_mode, :string, default: "auto"
    field :mcp, {:array, :string}, default: []
    # On unless a profile says otherwise: a pooled seat always goes out with
    # the preferred account and fails over with the pool (operator, 2026-10-07).
    field :pooled, :boolean, default: true
    field :autostart, :boolean, default: false
    # Left out of a bulk restart unless named; a single restart is confirmed (Restarts).
    field :protected, :boolean, default: false
    field :resume, :string, default: "latest"
    field :debug, :boolean, default: false
    field :last_start, :map

    belongs_to :user, ClaudiverseServer.Accounts.User
    timestamps()
  end

  def editable_fields, do: @editable

  @doc "A new profile: the name is set here and never again."
  def create_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:name, :user_id | @editable])
    |> validate_required([:name, :user_id, :machine, :folder])
    |> validate_format(:name, @name, message: "must be 1-64 of A-Z a-z 0-9 . _ -")
    |> unique_constraint([:user_id, :name], error_key: :name, message: "a profile with this name exists")
    |> validate_fields()
  end

  @doc "A rename: the name alone, checked as at creation."
  def rename_changeset(profile, name) do
    profile
    |> cast(%{name: name}, [:name])
    |> validate_required([:name])
    |> validate_format(:name, @name, message: "must be 1-64 of A-Z a-z 0-9 . _ -")
    |> unique_constraint([:user_id, :name], error_key: :name, message: "a profile with this name exists")
  end

  @doc "An edit: every field but the name; the revision is bumped by the caller."
  def update_changeset(profile, attrs) do
    profile
    |> cast(attrs, @editable)
    |> validate_fields()
  end

  defp validate_fields(cs) do
    cs
    |> validate_required([:machine, :folder, :role, :runtime, :permission_mode, :resume])
    |> validate_format(:folder, ~r{\A/}, message: "must be an absolute path")
    |> validate_format(:machine, @name)
    |> validate_format(:runtime, @runtime)
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:permission_mode, @modes, message: "must be one of #{Enum.join(@modes, ", ")} (never bypassPermissions)")
    |> validate_inclusion(:effort, @efforts)
    |> validate_change(:fleet, fn :fleet, v -> if is_nil(v) or Regex.match?(@name, v), do: [], else: [fleet: "must be 1-64 of A-Z a-z 0-9 . _ -"] end)
    |> validate_change(:mcp, fn :mcp, names ->
      if Enum.all?(names, &Regex.match?(@name, &1)), do: [], else: [mcp: "must be server names from the machine's catalog"]
    end)
    |> validate_change(:resume, fn :resume, v ->
      if v in ["latest", "new"] or Regex.match?(@uuid, v), do: [], else: [resume: "must be latest, new or a conversation id"]
    end)
  end
end
