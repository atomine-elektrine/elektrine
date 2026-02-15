defmodule Elektrine.Social.PostLike do
  use Ecto.Schema
  import Ecto.Changeset

  schema "post_likes" do
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :message, Elektrine.Messaging.Message
    field :created_at, :utc_datetime
  end

  @doc false
  def changeset(like, attrs) do
    like
    |> cast(attrs, [:user_id, :message_id])
    |> validate_required([:user_id, :message_id])
    |> unique_constraint([:user_id, :message_id])
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:message_id)
  end
end
