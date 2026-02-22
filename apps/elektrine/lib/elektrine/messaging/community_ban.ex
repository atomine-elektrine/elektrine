defmodule Elektrine.Messaging.CommunityBan do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "community_bans" do
    belongs_to :conversation, Elektrine.Messaging.Conversation
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :banned_by, Elektrine.Accounts.User
    field :reason, :string
    field :expires_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(ban, attrs) do
    ban
    |> cast(attrs, [:conversation_id, :user_id, :banned_by_id, :reason, :expires_at])
    |> validate_required([:conversation_id, :user_id, :banned_by_id])
    |> validate_length(:reason, max: 500)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:banned_by_id)
    |> unique_constraint([:conversation_id, :user_id])
  end
end
