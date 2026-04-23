defmodule Elektrine.Social.PollOption do
  @moduledoc """
  Schema for individual options in a poll.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "poll_options" do
    field :option_text, :string
    field :position, :integer, default: 0
    field :vote_count, :integer, default: 0

    belongs_to :poll, Elektrine.Social.Poll
    has_many :votes, Elektrine.Social.PollVote, foreign_key: :option_id

    timestamps()
  end

  @doc false
  def changeset(poll_option, attrs) do
    poll_option
    |> cast(attrs, [:poll_id, :option_text, :position, :vote_count])
    |> validate_required([:poll_id, :option_text])
    |> validate_length(:option_text, min: 1, max: 200)
    |> foreign_key_constraint(:poll_id)
  end
end
