defmodule ElektrineSocialWeb.DiscussionsLive.PostOperations.VotingOperations do
  @moduledoc """
  Handles voting operations for discussion post detail view.
  """

  import Phoenix.Component
  import Phoenix.LiveView
  import ElektrineWeb.Live.NotificationHelpers

  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Messages

  def handle_event("vote", %{"message_id" => message_id, "type" => vote_type}, socket) do
    if socket.assigns.current_user do
      user_id = socket.assigns.current_user.id

      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          current_vote = Map.get(socket.assigns[:user_votes] || %{}, message_id)
          updated_socket = optimistic_vote_update(socket, message_id, vote_type, current_vote)

          Social.vote_on_message(user_id, message_id, vote_type)

          {:noreply, updated_socket}

        :error ->
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

      with {:ok, poll_id} <- parse_positive_int(poll_id),
           {:ok, option_id} <- parse_positive_int(option_id) do
        case Social.vote_on_poll(poll_id, option_id, socket.assigns.current_user.id) do
          {:ok, _vote} ->
            updated_post = Messages.get_discussion_post!(socket.assigns.post.id, force: true)

            {:noreply,
             socket
             |> assign(:post, updated_post)
             |> put_flash(:info, "Vote recorded")}

          {:error, :poll_closed} ->
            {:noreply, notify_error(socket, "This poll has closed")}

          {:error, :invalid_option} ->
            {:noreply, notify_error(socket, "Invalid poll option")}

          {:error, :self_vote} ->
            {:noreply, notify_error(socket, "You cannot vote on your own poll")}

          {:error, _} ->
            {:noreply, notify_error(socket, "Failed to vote")}
        end
      else
        :error ->
          {:noreply, notify_error(socket, "Failed to vote")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to vote")}
    end
  end

  def handle_event("vote_remote_poll", %{"option_name" => option_name} = params, socket) do
    if socket.assigns.current_user do
      poll_id = params["poll_id"]

      remote_actor =
        with {:ok, message_id} <- parse_positive_int(params["message_id"]),
             %Elektrine.Social.Message{} = message <-
               Repo.get(Elektrine.Social.Message, message_id) do
          Repo.preload(message, [:remote_actor]).remote_actor
        else
          _ -> nil
        end

      if is_binary(poll_id) && remote_actor do
        Elektrine.ActivityPub.Outbox.send_poll_vote(
          socket.assigns.current_user,
          poll_id,
          option_name,
          remote_actor
        )

        {:noreply, put_flash(socket, :info, "Vote sent to #{remote_actor.domain}")}
      else
        {:noreply, notify_error(socket, "Unable to send remote poll vote")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to vote")}
    end
  end

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    if socket.assigns.current_user do
      case parse_positive_int(post_id) do
        {:ok, post_id} ->
          if socket.assigns.liked_by_user do
            Social.unlike_post(socket.assigns.current_user.id, post_id)
            {:noreply, assign(socket, :liked_by_user, false)}
          else
            Social.like_post(socket.assigns.current_user.id, post_id)
            {:noreply, assign(socket, :liked_by_user, true)}
          end

        :error ->
          {:noreply, notify_error(socket, "Failed to like post")}
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

      case parse_positive_int(post_id) do
        {:ok, message_id} ->
          alias Elektrine.Messaging.Reactions

          # Check if user already has this reaction
          existing_reaction =
            Elektrine.Repo.get_by(
              Elektrine.Social.MessageReaction,
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

        :error ->
          {:noreply, notify_error(socket, "Failed to react")}
      end
    else
      {:noreply, notify_error(socket, "Please sign in to react")}
    end
  end

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_positive_int(_value), do: :error

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

  defp optimistic_vote_update(socket, message_id, vote_type, current_vote) do
    {upvote_delta, downvote_delta, new_vote} =
      case {current_vote, vote_type} do
        {nil, "up"} -> {1, 0, "up"}
        {nil, "down"} -> {0, 1, "down"}
        {"up", "up"} -> {-1, 0, nil}
        {"down", "down"} -> {0, -1, nil}
        {"up", "down"} -> {-1, 1, "down"}
        {"down", "up"} -> {1, -1, "up"}
        _ -> {0, 0, current_vote}
      end

    user_votes = socket.assigns[:user_votes] || %{}

    updated_user_votes =
      if new_vote do
        Map.put(user_votes, message_id, new_vote)
      else
        Map.delete(user_votes, message_id)
      end

    socket
    |> assign(:user_votes, updated_user_votes)
    |> update_post_vote_counts(message_id, upvote_delta, downvote_delta)
    |> update_reply_vote_counts(message_id, upvote_delta, downvote_delta)
  end

  defp update_post_vote_counts(socket, message_id, upvote_delta, downvote_delta) do
    if socket.assigns.post.id == message_id do
      assign(socket, :post, apply_vote_delta(socket.assigns.post, upvote_delta, downvote_delta))
    else
      socket
    end
  end

  defp update_reply_vote_counts(socket, message_id, upvote_delta, downvote_delta) do
    assign(
      socket,
      :replies,
      update_threaded_reply_vote_counts(
        socket.assigns[:replies] || [],
        message_id,
        upvote_delta,
        downvote_delta
      )
    )
  end

  defp update_threaded_reply_vote_counts(
         threaded_replies,
         message_id,
         upvote_delta,
         downvote_delta
       )
       when is_list(threaded_replies) do
    Enum.map(threaded_replies, fn
      %{reply: reply, children: children} = node ->
        updated_reply =
          if reply.id == message_id do
            apply_vote_delta(reply, upvote_delta, downvote_delta)
          else
            reply
          end

        %{
          node
          | reply: updated_reply,
            children:
              update_threaded_reply_vote_counts(
                children,
                message_id,
                upvote_delta,
                downvote_delta
              )
        }

      other ->
        other
    end)
  end

  defp update_threaded_reply_vote_counts(
         threaded_replies,
         _message_id,
         _upvote_delta,
         _downvote_delta
       ),
       do: threaded_replies

  defp apply_vote_delta(message, upvote_delta, downvote_delta) do
    new_upvotes = (message.upvotes || 0) + upvote_delta
    new_downvotes = (message.downvotes || 0) + downvote_delta

    %{
      message
      | upvotes: new_upvotes,
        downvotes: new_downvotes,
        score: new_upvotes - new_downvotes
    }
  end
end
