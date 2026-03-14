defmodule ElektrineWeb.DiscussionsLive.Operations.VotingOperations do
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
      message_id = String.to_integer(message_id)

      # Optimistic update - update UI immediately
      current_user_vote = get_user_vote(socket, message_id)
      updated_socket = optimistic_vote_update(socket, message_id, vote_type, current_user_vote)

      # Perform database operation - run synchronously to ensure persistence
      # This is fast enough that it won't cause UI delays
      Social.vote_on_message(user_id, message_id, vote_type)

      {:noreply, updated_socket}
    else
      {:noreply, notify_error(socket, "You must be signed in to vote")}
    end
  end

  def handle_event("show_voters", %{"message_id" => message_id}, socket) do
    message_id = String.to_integer(message_id)

    # Get voters for this message
    {upvoters, downvoters} = Social.get_message_voters(message_id)

    {:noreply,
     socket
     |> assign(:show_voters_modal, true)
     |> assign(:voters_tab, "upvotes")
     |> assign(:upvoters, upvoters)
     |> assign(:downvoters, downvoters)}
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

      poll_id = String.to_integer(poll_id)
      option_id = String.to_integer(option_id)

      case Social.vote_on_poll(poll_id, option_id, socket.assigns.current_user.id) do
        {:ok, _vote} ->
          # Find the message that contains this poll and reload it
          poll = Repo.get!(Elektrine.Social.Poll, poll_id)
          message_id = poll.message_id

          # Reload the message with fresh poll data
          updated_message =
            Repo.get!(Elektrine.Messaging.Message, message_id)
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
            |> Elektrine.Messaging.Message.decrypt_content()

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
           |> assign(:pinned_posts, updated_pinned_posts)}

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

  # Private helpers

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
