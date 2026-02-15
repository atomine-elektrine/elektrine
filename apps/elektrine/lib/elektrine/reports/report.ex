defmodule Elektrine.Reports.Report do
  use Ecto.Schema
  import Ecto.Changeset
  alias Elektrine.Accounts.User

  @reasons ~w(spam harassment inappropriate violence hate_speech impersonation self_harm misinformation other)
  @statuses ~w(pending reviewing resolved dismissed)
  @priorities ~w(low normal high critical)
  @actions ~w(warned suspended banned content_removed no_action)

  schema "reports" do
    belongs_to :reporter, User
    belongs_to :reviewed_by, User

    field :reportable_type, :string
    field :reportable_id, :integer

    field :reason, :string
    field :description, :string
    field :screenshots, {:array, :string}, default: []

    field :status, :string, default: "pending"
    field :priority, :string, default: "normal"

    field :reviewed_at, :utc_datetime
    field :resolution_notes, :string
    field :action_taken, :string

    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [
      :reporter_id,
      :reportable_type,
      :reportable_id,
      :reason,
      :description,
      :screenshots,
      :status,
      :priority,
      :metadata
    ])
    |> validate_required([:reporter_id, :reportable_type, :reportable_id, :reason])
    |> validate_inclusion(:reason, @reasons)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_length(:description, max: 5000)
    |> foreign_key_constraint(:reporter_id)
  end

  def review_changeset(report, attrs) do
    report
    |> cast(attrs, [
      :status,
      :priority,
      :reviewed_by_id,
      :reviewed_at,
      :resolution_notes,
      :action_taken
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_inclusion(:action_taken, @actions)
    |> foreign_key_constraint(:reviewed_by_id)
  end

  def reasons, do: @reasons
  def statuses, do: @statuses
  def priorities, do: @priorities
  def actions, do: @actions
end
