defmodule ClaudiverseServer.Schedules.Schedule do
  @moduledoc """
  A scheduled prompt: `prompt` goes to the seat titled `target_title` at each
  time `cron` (5 fields) names in the zone `tz`. See ClaudiverseServer.Schedules.

  The prompt is stored exactly as given: never trimmed, normalised or cut. A
  schedule may fire into a brand-new seat, so the prompt is the whole brief;
  one over `max_prompt_chars/0` is refused, never shortened.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # Counted in Unicode code points, not bytes: "æ" and "🙂" are one each.
  @max_prompt_chars 20_000
  # Short, and never all digits, so a schedule can be named where an id is
  # expected (the API's /schedules/:id takes either).
  @name ~r/\A(?!\d+\z)[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/

  schema "schedules" do
    field :name, :string
    field :target_title, :string
    field :cron, :string
    field :tz, :string
    field :prompt, :string
    field :enabled, :boolean, default: true
    field :created_by, :string
    field :next_fire_at, :utc_datetime
    field :last_fired_at, :utc_datetime

    belongs_to :user, ClaudiverseServer.Accounts.User
    has_many :runs, ClaudiverseServer.Schedules.Run
    timestamps()
  end

  def max_prompt_chars, do: @max_prompt_chars

  @doc "A new schedule, or an edit of one (`attrs` names only what changes)."
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:name, :target_title, :cron, :tz, :prompt, :enabled, :user_id, :created_by])
    |> validate_required([:name, :target_title, :cron, :tz, :prompt, :user_id, :created_by])
    |> validate_format(:name, @name, message: "must be 1-64 of A-Z a-z 0-9 . _ -, start with a letter or digit, and not be all digits")
    |> validate_length(:target_title, max: 200)
    |> validate_prompt_length()
    |> validate_tz()
    |> validate_cron()
    |> unique_constraint([:user_id, :name], error_key: :name, message: "a schedule with this name exists")
  end

  # Ecto's own validate_length message says neither the limit nor the length
  # in a form a caller can act on; this one names both.
  defp validate_prompt_length(changeset) do
    validate_change(changeset, :prompt, fn :prompt, prompt ->
      case prompt |> String.codepoints() |> length() do
        n when n > @max_prompt_chars -> [prompt: "is #{n} characters; the limit is #{@max_prompt_chars}. Nothing was saved"]
        _ -> []
      end
    end)
  end

  defp validate_tz(changeset) do
    validate_change(changeset, :tz, fn :tz, tz ->
      if ClaudiverseServer.Schedules.Cron.valid_zone?(tz), do: [], else: [tz: "is not an IANA time zone (e.g. Europe/Oslo)"]
    end)
  end

  defp validate_cron(changeset) do
    validate_change(changeset, :cron, fn :cron, cron ->
      case ClaudiverseServer.Schedules.Cron.parse(cron) do
        {:ok, _} -> []
        {:error, why} -> [cron: why]
      end
    end)
  end
end
