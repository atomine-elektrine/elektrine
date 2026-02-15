defmodule Elektrine.Social.CreatorSatisfaction do
  @moduledoc """
  Tracks user satisfaction with specific creators over time.

  This helps the recommendation algorithm distinguish between:
  - Clickbait (high engagement but users regret clicking)
  - Quality content (users continue engaging with creator)

  Satisfaction signals:
  - followed_after_viewing: Strong positive - user followed after seeing content
  - continued_engagement: Positive - user kept viewing creator's content
  - immediate_leave: Negative - user left quickly after engaging
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "creator_satisfaction" do
    field :followed_after_viewing, :boolean, default: false
    field :continued_engagement, :boolean, default: false
    field :immediate_leave, :boolean, default: false
    field :total_posts_viewed, :integer, default: 0
    field :total_dwell_time_ms, :integer, default: 0

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :creator, Elektrine.Accounts.User
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    timestamps()
  end

  def changeset(satisfaction, attrs) do
    satisfaction
    |> cast(attrs, [
      :user_id,
      :creator_id,
      :remote_actor_id,
      :followed_after_viewing,
      :continued_engagement,
      :immediate_leave,
      :total_posts_viewed,
      :total_dwell_time_ms
    ])
    |> validate_required([:user_id])
    |> validate_has_creator()
    |> unique_constraint([:user_id, :creator_id],
      name: :creator_satisfaction_user_id_creator_id_index
    )
    |> unique_constraint([:user_id, :remote_actor_id],
      name: :creator_satisfaction_user_id_remote_actor_id_index
    )
  end

  defp validate_has_creator(changeset) do
    creator_id = get_field(changeset, :creator_id)
    remote_actor_id = get_field(changeset, :remote_actor_id)

    if is_nil(creator_id) && is_nil(remote_actor_id) do
      add_error(changeset, :creator_id, "must have either creator_id or remote_actor_id")
    else
      changeset
    end
  end

  @doc """
  Calculates a satisfaction score from 0.0 to 1.0.
  Higher = users are satisfied with this creator's content.
  """
  def satisfaction_score(%__MODULE__{} = sat) do
    # Neutral starting point
    base = 0.5

    # Positive signals
    base = if sat.followed_after_viewing, do: base + 0.3, else: base
    base = if sat.continued_engagement, do: base + 0.2, else: base

    # Negative signals
    base = if sat.immediate_leave, do: base - 0.3, else: base

    # Engagement depth (avg dwell time per post)
    avg_dwell =
      if sat.total_posts_viewed > 0 do
        sat.total_dwell_time_ms / sat.total_posts_viewed
      else
        0
      end

    # Boost for high average dwell time (30+ seconds)
    base = if avg_dwell > 30_000, do: base + 0.1, else: base

    # Clamp to 0.0-1.0
    min(max(base, 0.0), 1.0)
  end
end
