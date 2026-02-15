defmodule Elektrine.Social.HashtagFollow do
  @moduledoc """
  Schema for tracking hashtag follows.

  Users can follow hashtags to see posts containing them in their home timeline.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "hashtag_follows" do
    belongs_to(:user, Elektrine.Accounts.User)
    belongs_to(:hashtag, Elektrine.Social.Hashtag)

    timestamps()
  end

  @doc false
  def changeset(hashtag_follow, attrs) do
    hashtag_follow
    |> cast(attrs, [:user_id, :hashtag_id])
    |> validate_required([:user_id, :hashtag_id])
    |> unique_constraint([:user_id, :hashtag_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:hashtag_id)
  end
end
