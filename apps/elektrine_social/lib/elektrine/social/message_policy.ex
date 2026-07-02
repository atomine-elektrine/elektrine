defmodule Elektrine.Social.MessagePolicy do
  @moduledoc """
  Central interaction policy for social messages.
  """

  import Ecto.Query

  alias Elektrine.Friends
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias Elektrine.Social.{ConversationMember, Message}

  @public_visibilities ["public", "unlisted"]

  def visible?(_user_id, %Message{deleted_at: deleted_at}) when not is_nil(deleted_at), do: false

  def visible?(_user_id, %Message{visibility: visibility})
      when visibility in @public_visibilities, do: true

  def visible?(user_id, %Message{sender_id: sender_id, visibility: "followers"})
      when is_integer(user_id) and is_integer(sender_id),
      do: user_id == sender_id or Profiles.following?(user_id, sender_id)

  def visible?(user_id, %Message{sender_id: sender_id, visibility: "friends"})
      when is_integer(user_id) and is_integer(sender_id),
      do: user_id == sender_id or Friends.are_friends?(user_id, sender_id)

  def visible?(user_id, %Message{remote_actor_id: actor_id, visibility: visibility})
      when is_integer(user_id) and is_integer(actor_id) and
             visibility in ["public", "unlisted", "followers"],
      do: following_remote_actor?(user_id, actor_id)

  def visible?(user_id, %Message{
        conversation_id: conversation_id,
        sender_id: sender_id,
        visibility: "direct"
      })
      when is_integer(user_id) and is_integer(conversation_id) do
    user_id == sender_id or active_conversation_member?(user_id, conversation_id)
  end

  def visible?(user_id, %Message{sender_id: sender_id}) when is_integer(user_id),
    do: user_id == sender_id

  def visible?(_user_id, _message), do: false

  def like?(user_id, %Message{} = message), do: can_interact?(user_id, message)
  def save?(user_id, %Message{} = message), do: can_interact?(user_id, message)
  def reply?(user_id, %Message{} = message), do: can_interact?(user_id, message)

  def boost?(user_id, %Message{} = message) do
    can_interact?(user_id, message) and message.visibility in @public_visibilities
  end

  def quote?(user_id, %Message{} = message), do: boost?(user_id, message)

  def delete?(user_id, %Message{sender_id: sender_id}) when is_integer(user_id),
    do: user_id == sender_id

  def delete?(_user_id, _message), do: false

  defp can_interact?(user_id, %Message{} = message) when is_integer(user_id) do
    visible?(user_id, message)
  end

  defp can_interact?(_, _), do: false

  defp following_remote_actor?(user_id, remote_actor_id) do
    Repo.exists?(
      from f in Follow,
        where:
          f.follower_id == ^user_id and f.remote_actor_id == ^remote_actor_id and
            f.pending == false
    )
  end

  defp active_conversation_member?(user_id, conversation_id) do
    Repo.exists?(
      from member in ConversationMember,
        where:
          member.user_id == ^user_id and member.conversation_id == ^conversation_id and
            is_nil(member.left_at)
    )
  end
end
