defmodule Elektrine.Messaging.ChatMessageReaction do
  @moduledoc """
  Schema for reactions to chat messages.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "chat_message_reactions" do
    field :emoji, :string

    belongs_to :chat_message, Elektrine.Messaging.ChatMessage
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :remote_actor, Elektrine.ActivityPub.Actor

    timestamps()
  end

  @doc false
  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:chat_message_id, :user_id, :remote_actor_id, :emoji])
    |> validate_required([:chat_message_id, :emoji])
    |> validate_user_or_remote_actor()
    |> validate_length(:emoji, max: 50)
    |> foreign_key_constraint(:chat_message_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:remote_actor_id)
  end

  defp validate_user_or_remote_actor(changeset) do
    user_id = get_field(changeset, :user_id)
    remote_actor_id = get_field(changeset, :remote_actor_id)

    cond do
      is_nil(user_id) and is_nil(remote_actor_id) ->
        add_error(changeset, :user_id, "either user_id or remote_actor_id must be present")

      not is_nil(user_id) and not is_nil(remote_actor_id) ->
        add_error(changeset, :user_id, "only one of user_id or remote_actor_id can be present")

      true ->
        changeset
    end
  end
end
