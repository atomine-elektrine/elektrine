defmodule Elektrine.Messaging.FederatedReplies do
  @moduledoc """
  Handles replies to federated posts.
  """

  import Ecto.Query
  alias Elektrine.ActivityPub
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

  @doc """
  Creates a reply to a federated post.
  This doesn't require a conversation_id since federated posts don't have one.
  """
  def reply_to_federated_post(federated_message_id, sender_id, content) do
    federated_message = Repo.get(Message, federated_message_id)

    if federated_message && federated_message.federated do
      # Create the reply using federated changeset (no conversation_id needed)
      attrs = %{
        content: content,
        # Replies to public posts are public
        visibility: "public",
        reply_to_id: federated_message_id,
        sender_id: sender_id,
        activitypub_id:
          "#{ActivityPub.instance_url()}/users/#{get_username(sender_id)}/statuses/#{Ecto.UUID.generate()}",
        # This is a local reply to a federated post
        federated: false
      }

      case %Message{}
           |> Message.changeset(attrs)
           |> Repo.insert() do
        {:ok, reply} ->
          # Federate the reply to the remote author
          Task.start(fn ->
            reply_with_sender = Repo.preload(reply, :sender)
            Elektrine.ActivityPub.Outbox.federate_post(reply_with_sender)
          end)

          {:ok, reply}

        error ->
          error
      end
    else
      {:error, :not_federated_post}
    end
  end

  defp get_username(user_id) do
    from(u in Elektrine.Accounts.User, where: u.id == ^user_id, select: u.username)
    |> Repo.one()
  end
end
