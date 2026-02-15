defmodule Elektrine.Social.Poll do
  @moduledoc """
  Schema for polls attached to discussion posts.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "polls" do
    field(:question, :string)
    field(:closes_at, :utc_datetime)
    field(:allow_multiple, :boolean, default: false)
    field(:total_votes, :integer, default: 0)
    # Unique voters count (for polls where users can vote on multiple options)
    field(:voters_count, :integer, default: 0)
    # Track voter actor URIs for federated polls (like Akkoma's "voters" array)
    field(:voter_uris, {:array, :string}, default: [])

    belongs_to(:message, Elektrine.Messaging.Message)
    has_many(:options, Elektrine.Social.PollOption, foreign_key: :poll_id)
    has_many(:votes, Elektrine.Social.PollVote, foreign_key: :poll_id)

    timestamps()
  end

  @doc false
  def changeset(poll, attrs) do
    poll
    |> cast(attrs, [
      :message_id,
      :question,
      :closes_at,
      :allow_multiple,
      :total_votes,
      :voters_count,
      :voter_uris
    ])
    |> validate_required([:message_id, :question])
    |> validate_length(:question, min: 3, max: 300)
    |> foreign_key_constraint(:message_id)
  end

  @doc """
  Records a voter for federated polls.
  Used to track unique voters and prevent double-voting from remote users.
  """
  def record_voter(%__MODULE__{voter_uris: uris} = poll, actor_uri) when is_binary(actor_uri) do
    if actor_uri in (uris || []) do
      {:ok, poll}
    else
      new_uris = [actor_uri | uris || []] |> Enum.uniq()

      poll
      |> Ecto.Changeset.change(%{
        voter_uris: new_uris,
        voters_count: length(new_uris)
      })
      |> Elektrine.Repo.update()
    end
  end

  @doc """
  Checks if an actor has already voted on this poll.
  """
  def has_voted?(%__MODULE__{voter_uris: uris}, actor_uri) do
    actor_uri in (uris || [])
  end

  @doc """
  Checks if the poll is still open for voting.
  """
  def open?(%__MODULE__{closes_at: nil}), do: true

  def open?(%__MODULE__{closes_at: closes_at}) do
    DateTime.compare(DateTime.utc_now(), closes_at) == :lt
  end

  @doc """
  Checks if the poll has closed.
  """
  def closed?(poll), do: !open?(poll)
end
