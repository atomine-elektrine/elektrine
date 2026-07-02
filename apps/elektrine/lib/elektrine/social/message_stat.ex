defmodule Elektrine.Social.MessageStat do
  @moduledoc """
  Durable counter row for social messages.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "social_message_stats" do
    belongs_to :message, Elektrine.Social.Message

    field :like_count, :integer, default: 0
    field :reply_count, :integer, default: 0
    field :share_count, :integer, default: 0
    field :quote_count, :integer, default: 0
    field :remote_like_count, :integer
    field :remote_reply_count, :integer
    field :remote_share_count, :integer
    field :remote_quote_count, :integer
    field :remote_counts_fetched_at, :utc_datetime

    timestamps()
  end

  def changeset(stat, attrs) do
    stat
    |> cast(attrs, [
      :message_id,
      :like_count,
      :reply_count,
      :share_count,
      :quote_count,
      :remote_like_count,
      :remote_reply_count,
      :remote_share_count,
      :remote_quote_count,
      :remote_counts_fetched_at
    ])
    |> validate_required([:message_id])
    |> clamp_remote_counts()
    |> unique_constraint(:message_id)
  end

  defp clamp_remote_counts(changeset) do
    Enum.reduce(Elektrine.Social.EngagementCounts.remote_fields(), changeset, fn field, acc ->
      update_change(acc, field, &Elektrine.Social.EngagementCounts.nullable_remote_count/1)
    end)
  end
end
