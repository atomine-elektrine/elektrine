defmodule Elektrine.Social.PollVote do
  @moduledoc """
  Schema for tracking individual votes on poll options.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "poll_votes" do
    belongs_to :poll, Elektrine.Social.Poll
    belongs_to :option, Elektrine.Social.PollOption
    belongs_to :user, Elektrine.Accounts.User

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(poll_vote, attrs) do
    poll_vote
    |> cast(attrs, [:poll_id, :option_id, :user_id])
    |> validate_required([:poll_id, :option_id, :user_id])
    |> unique_constraint([:poll_id, :user_id, :option_id],
      name: :poll_votes_poll_id_user_id_option_id_index
    )
    |> foreign_key_constraint(:poll_id)
    |> foreign_key_constraint(:option_id)
    |> foreign_key_constraint(:user_id)
  end
end
