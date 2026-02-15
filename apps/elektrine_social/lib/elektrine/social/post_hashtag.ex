defmodule Elektrine.Social.PostHashtag do
  use Ecto.Schema
  import Ecto.Changeset

  schema "post_hashtags" do
    belongs_to :message, Elektrine.Messaging.Message
    belongs_to :hashtag, Elektrine.Social.Hashtag

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(post_hashtag, attrs) do
    post_hashtag
    |> cast(attrs, [:message_id, :hashtag_id])
    |> validate_required([:message_id, :hashtag_id])
    |> unique_constraint([:message_id, :hashtag_id])
  end
end
