defmodule Elektrine.Social.PostView do
  use Ecto.Schema
  import Ecto.Changeset

  schema "post_views" do
    field :view_duration_seconds, :integer
    field :completed, :boolean, default: false
    # milliseconds spent on post
    field :dwell_time_ms, :integer
    # 0.0-1.0 how much of post was visible
    field :scroll_depth, :float
    # clicked to expand/read more
    field :expanded, :boolean, default: false
    # where they saw the post (feed, profile, search, etc.)
    field :source, :string

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :message, Elektrine.Messaging.Message

    timestamps(updated_at: false)
  end

  def changeset(view, attrs) do
    view
    |> cast(attrs, [
      :user_id,
      :message_id,
      :view_duration_seconds,
      :completed,
      :dwell_time_ms,
      :scroll_depth,
      :expanded,
      :source
    ])
    |> validate_required([:user_id, :message_id])
    |> validate_number(:scroll_depth, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> unique_constraint([:user_id, :message_id],
      name: :post_views_user_id_message_id_index,
      message: "already viewed"
    )
  end

  @doc """
  Updates dwell time for an existing view record.
  Used to accumulate time as user continues viewing.
  """
  def update_dwell_changeset(view, attrs) do
    view
    |> cast(attrs, [:dwell_time_ms, :scroll_depth, :expanded])
    |> validate_number(:scroll_depth, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
  end
end
