defmodule ElektrineSocialWeb.DiscussionsLive.Operations.VotingOperations do
  @moduledoc """
  Handles all voting-related operations: post voting, poll voting, showing voters.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  # Import verified routes for ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.{Repo, Social}

  @doc "Vote on a post (upvote/downvote)"
  def handle_event("vote", %{"message_id" => message_id, "type" => vote_type}, socket) do
    if socket.assigns.current_user do
      user_id = socket.assigns.current_user.id

      case parse_positive_int(message_id) do
        {:ok, message_id} ->
          # Optimistic update - update UI immediately
          current_user_vote = get_user_vote(socket, message_id)

          updated_socket =
            optimistic_vote_update(socket, message_id, vote_type, current_user_vote)

          # Perform database operation - run synchronously to ensure persistence
          # This is fast enough that it won't cause UI delays
          Social.vote_on_message(user_id, message_id, vote_type)

          {:noreply, updated_socket}

        :error ->
          {:noreply, notify_error(socket, "Failed to vote")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to vote")}
    end
  end

  def handle_event("show_voters", %{"message_id" => message_id}, socket) do
    case parse_positive_int(message_id) do
      {:ok, message_id} ->
        # Get voters for this message
        {upvoters, downvoters} = Social.get_message_voters(message_id)

        {:noreply,
         socket
         |> assign(:show_voters_modal, true)
         |> assign(:voters_tab, "upvotes")
         |> assign(:upvoters, upvoters)
         |> assign(:downvoters, downvoters)}

      :error ->
        {:noreply, notify_error(socket, "Failed to load voters")}
    end
  end

  def handle_event("close_voters", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_voters_modal, false)
     |> assign(:upvoters, [])
     |> assign(:downvoters, [])}
  end

  def handle_event("switch_voters_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :voters_tab, tab)}
  end

  def handle_event("vote_poll", params, socket) do
    if socket.assigns.current_user do
      # Handle both hyphenated and underscore versions
      poll_id = params["poll_id"] || params["poll-id"]
      option_id = params["option_id"] || params["option-id"]

      with {:ok, poll_id} <- parse_positive_int(poll_id),
           {:ok, option_id} <- parse_positive_int(option_id) do
        case Social.vote_on_poll(poll_id, option_id, socket.assigns.current_user.id) do
          {:ok, _vote} ->
            case load_poll_message(poll_id) do
              {:ok, message_id, updated_message} ->
                # Update the post in discussion_posts or pinned_posts
                updated_discussion_posts =
                  Enum.map(socket.assigns.discussion_posts, fn post ->
                    if post.id == message_id, do: updated_message, else: post
                  end)

                updated_pinned_posts =
                  Enum.map(socket.assigns.pinned_posts, fn post ->
                    if post.id == message_id, do: updated_message, else: post
                  end)

                {:noreply,
                 socket
                 |> assign(:discussion_posts, updated_discussion_posts)
                 |> assign(:pinned_posts, updated_pinned_posts)
                 |> put_flash(:info, "Vote recorded")}

              :error ->
                {:noreply, notify_error(socket, "Failed to vote")}
            end

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
        case parse_positive_int(params["message_id"]) do
          {:ok, message_id} ->
            socket.assigns.discussion_posts
            |> Enum.find(&(&1.id == message_id))
            |> case do
              %{remote_actor: remote_actor} when is_map(remote_actor) -> remote_actor
              _ -> nil
            end

          :error ->
            nil
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

  # Private helpers

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_positive_int(_value), do: :error

  defp load_poll_message(poll_id) do
    with %Elektrine.Social.Poll{message_id: message_id} <-
           Repo.get(Elektrine.Social.Poll, poll_id),
         %Elektrine.Social.Message{} = message <- Repo.get(Elektrine.Social.Message, message_id) do
      updated_message =
        message
        |> Repo.preload(
          [
            sender: [:profile],
            link_preview: [],
            flair: [],
            shared_message: [sender: [:profile], conversation: []],
            poll: [options: []]
          ],
          force: true
        )
        |> Elektrine.Social.Message.decrypt_content()

      {:ok, message_id, updated_message}
    else
      _ -> :error
    end
  end

  defp get_user_vote(socket, message_id) do
    user_votes = socket.assigns[:user_votes] || %{}
    Map.get(user_votes, message_id)
  end

  defp optimistic_vote_update(socket, message_id, vote_type, current_vote) do
    # Calculate the delta based on current vote state and new vote
    {upvote_delta, downvote_delta, new_vote} =
      case {current_vote, vote_type} do
        # No current vote
        {nil, "up"} -> {1, 0, "up"}
        {nil, "down"} -> {0, 1, "down"}
        # Toggling same vote off
        {"up", "up"} -> {-1, 0, nil}
        {"down", "down"} -> {0, -1, nil}
        # Switching votes
        {"up", "down"} -> {-1, 1, "down"}
        {"down", "up"} -> {1, -1, "up"}
        # Default
        _ -> {0, 0, current_vote}
      end

    # Update user_votes map
    user_votes = socket.assigns[:user_votes] || %{}

    updated_user_votes =
      if new_vote do
        Map.put(user_votes, message_id, new_vote)
      else
        Map.delete(user_votes, message_id)
      end

    socket
    |> assign(:user_votes, updated_user_votes)
    |> update(:discussion_posts, fn posts ->
      Enum.map(posts, fn post ->
        if post.id == message_id do
          new_upvotes = (post.upvotes || 0) + upvote_delta
          new_downvotes = (post.downvotes || 0) + downvote_delta

          %{
            post
            | upvotes: new_upvotes,
              downvotes: new_downvotes,
              score: new_upvotes - new_downvotes
          }
        else
          post
        end
      end)
    end)
    |> update(:pinned_posts, fn posts ->
      Enum.map(posts, fn post ->
        if post.id == message_id do
          new_upvotes = (post.upvotes || 0) + upvote_delta
          new_downvotes = (post.downvotes || 0) + downvote_delta

          %{
            post
            | upvotes: new_upvotes,
              downvotes: new_downvotes,
              score: new_upvotes - new_downvotes
          }
        else
          post
        end
      end)
    end)
  end

  defp notify_error(socket, message) do
    put_flash(socket, :error, message)
  end
end
