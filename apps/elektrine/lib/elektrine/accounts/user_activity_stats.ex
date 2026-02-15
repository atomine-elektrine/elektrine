defmodule Elektrine.Accounts.UserActivityStats do
  @moduledoc """
  Tracks user activity metrics for trust level calculation.
  Similar to Discourse's user_stats table.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_activity_stats" do
    belongs_to :user, Elektrine.Accounts.User

    # Content creation
    field :posts_created, :integer, default: 0
    field :topics_created, :integer, default: 0
    field :replies_created, :integer, default: 0

    # Engagement metrics
    field :likes_given, :integer, default: 0
    field :likes_received, :integer, default: 0
    field :replies_received, :integer, default: 0

    # Reading metrics
    field :posts_read, :integer, default: 0
    field :topics_entered, :integer, default: 0
    field :time_read_seconds, :integer, default: 0

    # Visit tracking
    field :days_visited, :integer, default: 0
    field :last_visit_date, :date

    # Moderation
    field :flags_given, :integer, default: 0
    field :flags_received, :integer, default: 0
    field :flags_agreed, :integer, default: 0

    # Penalties
    field :posts_deleted, :integer, default: 0
    field :suspensions_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(stats, attrs) do
    stats
    |> cast(attrs, [
      :posts_created,
      :topics_created,
      :replies_created,
      :likes_given,
      :likes_received,
      :replies_received,
      :posts_read,
      :topics_entered,
      :time_read_seconds,
      :days_visited,
      :last_visit_date,
      :flags_given,
      :flags_received,
      :flags_agreed,
      :posts_deleted,
      :suspensions_count
    ])
    |> validate_number(:posts_created, greater_than_or_equal_to: 0)
    |> validate_number(:days_visited, greater_than_or_equal_to: 0)
  end

  @doc """
  Increment a stat by a given amount.
  """
  def increment(stats, field, amount \\ 1) do
    current_value = Map.get(stats, field, 0)
    changeset(stats, %{field => current_value + amount})
  end
end
