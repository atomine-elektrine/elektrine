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
    field(:hide_totals, :boolean, default: false)
    field(:total_votes, :integer, default: 0)
    field(:voters_count, :integer, default: 0)
    field(:voter_uris, {:array, :string}, default: [])
    field(:last_fetched_at, :utc_datetime)

    belongs_to(:message, Elektrine.Social.Message)
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
      :hide_totals,
      :total_votes,
      :voters_count,
      :voter_uris,
      :last_fetched_at
    ])
    |> validate_required([:message_id, :question])
    |> validate_length(:question, min: 3, max: 300)
    |> foreign_key_constraint(:message_id)
  end

  def record_voter(%__MODULE__{voter_uris: uris} = poll, actor_uri) when is_binary(actor_uri) do
    if actor_uri in (uris || []) do
      {:ok, poll}
    else
      new_uris = [actor_uri | uris || []] |> Enum.uniq()

      poll
      |> Ecto.Changeset.change(%{voter_uris: new_uris, voters_count: length(new_uris)})
      |> Elektrine.Repo.update()
    end
  end

  def has_voted?(%__MODULE__{voter_uris: uris}, actor_uri) do
    actor_uri in (uris || [])
  end

  def open?(%{closes_at: nil}), do: true

  def open?(%{closes_at: %DateTime{} = closes_at}) do
    DateTime.compare(DateTime.utc_now(), closes_at) == :lt
  end

  def open?(%{closes_at: %NaiveDateTime{} = closes_at}) do
    closes_at
    |> DateTime.from_naive!("Etc/UTC")
    |> then(&(DateTime.compare(DateTime.utc_now(), &1) == :lt))
  end

  def open?(%{closes_at: closes_at}) when is_binary(closes_at) do
    case DateTime.from_iso8601(closes_at) do
      {:ok, datetime, _offset} -> DateTime.compare(DateTime.utc_now(), datetime) == :lt
      _ -> false
    end
  end

  def open?(_poll), do: false
  def closed?(poll), do: !open?(poll)

  def possibly_stale?(%{last_fetched_at: last_fetched_at, closes_at: closes_at}) do
    expires_after_last_fetch? =
      is_nil(closes_at) or is_nil(last_fetched_at) or
        DateTime.compare(last_fetched_at, closes_at) == :lt

    stale_fetch? =
      is_nil(last_fetched_at) or
        DateTime.compare(last_fetched_at, DateTime.add(DateTime.utc_now(), -60, :second)) == :lt

    expires_after_last_fetch? and stale_fetch?
  end

  def possibly_stale?(_poll), do: true
end
