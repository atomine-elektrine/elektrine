defmodule Elektrine.Social.PostBoost do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "post_boosts" do
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :message, Elektrine.Messaging.Message

    field :activitypub_id, :string

    timestamps(type: :naive_datetime)
  end

  @doc false
  def changeset(boost, attrs) do
    boost
    |> cast(attrs, [:user_id, :message_id, :activitypub_id])
    |> validate_required([:user_id, :message_id])
    |> unique_constraint([:user_id, :message_id])
  end
end
