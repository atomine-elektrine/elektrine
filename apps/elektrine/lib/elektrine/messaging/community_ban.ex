defmodule Elektrine.Messaging.CommunityBan do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "community_bans" do
    belongs_to :conversation, Elektrine.Messaging.Conversation
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :banned_by, Elektrine.Accounts.User
    field :origin_domain, :string
    field :actor_payload, :map, default: %{}
    field :metadata, :map, default: %{}
    field :reason, :string
    field :expires_at, :utc_datetime
    field :banned_at_remote, :utc_datetime
    field :updated_at_remote, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(ban, attrs) do
    ban
    |> cast(attrs, [
      :conversation_id,
      :user_id,
      :banned_by_id,
      :origin_domain,
      :actor_payload,
      :metadata,
      :reason,
      :expires_at,
      :banned_at_remote,
      :updated_at_remote
    ])
    |> validate_required([:conversation_id, :user_id])
    |> validate_ban_actor()
    |> validate_length(:reason, max: 500)
    |> validate_length(:origin_domain, max: 255)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:banned_by_id)
    |> unique_constraint([:conversation_id, :user_id])
  end

  defp validate_ban_actor(changeset) do
    banned_by_id = get_field(changeset, :banned_by_id)
    actor_payload = get_field(changeset, :actor_payload) || %{}
    origin_domain = get_field(changeset, :origin_domain)

    cond do
      is_integer(banned_by_id) ->
        changeset

      map_size(actor_payload) > 0 and Elektrine.Strings.present?(origin_domain) ->
        changeset

      true ->
        add_error(changeset, :banned_by_id, "must be present for local bans or remote actor bans")
    end
  end
end
