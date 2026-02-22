defmodule Elektrine.ActivityPub.Activity do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "activitypub_activities" do
    field :activity_id, :string
    field :activity_type, :string
    field :actor_uri, :string
    field :object_id, :string
    field :data, :map
    field :local, :boolean, default: false

    # Processing state for async handling
    field :processed, :boolean, default: false
    field :processed_at, :utc_datetime
    field :process_error, :string
    field :process_attempts, :integer, default: 0

    belongs_to :internal_user, Elektrine.Accounts.User
    belongs_to :internal_message, Elektrine.Messaging.Message

    has_many :deliveries, Elektrine.ActivityPub.Delivery

    timestamps()
  end

  @doc false
  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [
      :activity_id,
      :activity_type,
      :actor_uri,
      :object_id,
      :data,
      :local,
      :internal_user_id,
      :internal_message_id,
      :processed,
      :processed_at,
      :process_error,
      :process_attempts
    ])
    |> validate_required([:activity_id, :activity_type, :actor_uri, :data])
    |> unique_constraint(:activity_id)
  end

  @doc """
  Changeset for marking an activity as processed.
  """
  def mark_processed_changeset(activity, attrs \\ %{}) do
    activity
    |> cast(attrs, [:processed, :processed_at, :process_error, :process_attempts])
  end
end
