defmodule ElektrineWeb.DiscussionsLive.PostOperations.VotingOperations do
  @moduledoc """
  Handles voting operations for discussion post detail view.
  """

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  alias Elektrine.Social
  alias Elektrine.Messaging.Messages

  def handle_event("vote", %{"message_id" => message_id, "type" => vote_type}, socket) do
    if socket.assigns.current_user do
      user_id = socket.assigns.current_user.id
      message_id = String.to_integer(message_id)

      # Get current vote state for optimistic update
      user_votes = Map.get(socket.assigns, :user_votes, %{})
      current_vote = Map.get(user_votes, message_id)

      # Calculate new vote state
      new_vote =
        if current_vote == vote_type, do: nil, else: vote_type

      # Update user_votes optimistically
      updated_user_votes =
        if new_vote do
          Map.put(user_votes, message_id, new_vote)
        else
          Map.delete(user_votes, message_id)
        end

      case Social.vote_on_message(user_id, message_id, vote_type) do
        {:ok, _} ->
          socket = assign(socket, :user_votes, updated_user_votes)

          if message_id == socket.assigns.post.id do
            updated_post = Messages.get_discussion_post!(message_id)
            {:noreply, assign(socket, :post, updated_post)}
          else
            {:ok, _post, updated_replies} =
              get_post_with_replies_expanded(
                socket.assigns.post.id,
                socket.assigns.community.id,
                socket.assigns.expanded_threads
              )

            {:noreply, assign(socket, :replies, updated_replies)}
          end

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to vote")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to vote")}
    end
  end

  def handle_event("vote_poll", params, socket) do
    if socket.assigns.current_user do
      poll_id = params["poll_id"] || params["poll-id"]
      option_id = params["option_id"] || params["option-id"]

      poll_id = String.to_integer(poll_id)
      option_id = String.to_integer(option_id)

      case Social.vote_on_poll(poll_id, option_id, socket.assigns.current_user.id) do
        {:ok, _vote} ->
          updated_post = Messages.get_discussion_post!(socket.assigns.post.id, force: true)
          {:noreply, assign(socket, :post, updated_post)}

        {:error, :poll_closed} ->
          {:noreply, notify_error(socket, "This poll has closed")}

        {:error, :invalid_option} ->
          {:noreply, notify_error(socket, "Invalid poll option")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to vote")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to vote")}
    end
  end

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    if socket.assigns.current_user do
      post_id = String.to_integer(post_id)

      if socket.assigns.liked_by_user do
        Social.unlike_post(socket.assigns.current_user.id, post_id)
        {:noreply, assign(socket, :liked_by_user, false)}
      else
        Social.like_post(socket.assigns.current_user.id, post_id)
        {:noreply, assign(socket, :liked_by_user, true)}
      end
    else
      {:noreply, notify_error(socket, "Please sign in to like posts")}
    end
  end

  # Modal like toggle (for image modal)
  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    handle_event("like_post", %{"post_id" => post_id}, socket)
  end

  def handle_event("react_to_post", %{"post_id" => post_id, "emoji" => emoji}, socket) do
    if socket.assigns.current_user do
      user_id = socket.assigns.current_user.id
      message_id = String.to_integer(post_id)

      alias Elektrine.Messaging.Reactions

      # Check if user already has this reaction
      existing_reaction =
        Elektrine.Repo.get_by(
          Elektrine.Messaging.MessageReaction,
          message_id: message_id,
          user_id: user_id,
          emoji: emoji
        )

      if existing_reaction do
        # Remove the existing reaction
        case Reactions.remove_reaction(message_id, user_id, emoji) do
          {:ok, _} ->
            updated_reactions =
              update_post_reactions(
                socket,
                message_id,
                %{emoji: emoji, user_id: user_id},
                :remove
              )

            {:noreply, assign(socket, :post_reactions, updated_reactions)}

          {:error, _} ->
            {:noreply, socket}
        end
      else
        # Add new reaction
        case Reactions.add_reaction(message_id, user_id, emoji) do
          {:ok, reaction} ->
            reaction = Elektrine.Repo.preload(reaction, [:user, :remote_actor])
            updated_reactions = update_post_reactions(socket, message_id, reaction, :add)
            {:noreply, assign(socket, :post_reactions, updated_reactions)}

          {:error, :rate_limited} ->
            {:noreply, notify_error(socket, "Slow down! You're reacting too fast")}

          {:error, _} ->
            {:noreply, socket}
        end
      end
    else
      {:noreply, notify_error(socket, "Please sign in to react")}
    end
  end

  defp update_post_reactions(socket, message_id, reaction, action) do
    current_reactions = Map.get(socket.assigns, :post_reactions, %{})
    post_reactions = Map.get(current_reactions, message_id, [])

    updated =
      case action do
        :add ->
          if Enum.any?(post_reactions, fn r ->
               r.emoji == reaction.emoji && r.user_id == reaction.user_id
             end) do
            post_reactions
          else
            [reaction | post_reactions]
          end

        :remove ->
          Enum.reject(post_reactions, fn r ->
            r.emoji == reaction.emoji && r.user_id == reaction.user_id
          end)
      end

    Map.put(current_reactions, message_id, updated)
  end

  # Helper function
  defp get_post_with_replies_expanded(post_id, community_id, expanded_threads) do
    import Ecto.Query
    alias Elektrine.Repo
    alias Elektrine.Messaging.Message

    post =
      from(m in Message,
        where: m.id == ^post_id and m.conversation_id == ^community_id,
        preload: ^Messages.discussion_post_preloads()
      )
      |> Repo.one()

    case post do
      nil ->
        {:error, :not_found}

      post ->
        post = Message.decrypt_content(post)
        replies = get_threaded_replies_with_expansion(post_id, community_id, 0, expanded_threads)
        {:ok, post, replies}
    end
  end

  defp get_threaded_replies_with_expansion(parent_id, community_id, depth, expanded_threads) do
    import Ecto.Query
    alias Elektrine.Repo
    alias Elektrine.Messaging.Message

    direct_replies =
      from(m in Message,
        where:
          m.reply_to_id == ^parent_id and
            m.conversation_id == ^community_id and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)),
        order_by: [desc: m.score, asc: m.inserted_at],
        preload: [
          sender: [:profile],
          flair: [],
          shared_message: [sender: [:profile], conversation: []]
        ]
      )
      |> Repo.all()
      |> Enum.map(&Message.decrypt_content/1)

    Enum.map(direct_replies, fn reply ->
      should_expand = depth < 2 || MapSet.member?(expanded_threads, reply.id)

      nested_replies =
        if should_expand && depth < 10 do
          get_threaded_replies_with_expansion(reply.id, community_id, depth + 1, expanded_threads)
        else
          []
        end

      %{reply: reply, children: nested_replies, depth: depth, has_children: should_expand}
    end)
  end
end
