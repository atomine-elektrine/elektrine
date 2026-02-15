defmodule ElektrineWeb.FriendsLive do
  use ElektrineWeb, :live_view

  alias Elektrine.Friends
  alias Elektrine.Messaging
  import ElektrineWeb.Components.User.Avatar
  import ElektrineWeb.Components.Presence.Helpers
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Live.NotificationHelpers

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # Load cached friends immediately to prevent flicker
    {:ok, cached_friends} =
      Elektrine.AppCache.get_friends(user.id, fn ->
        Friends.list_friends(user.id)
      end)

    {:ok, cached_pending} =
      Elektrine.AppCache.get_pending_friend_requests(user.id, fn ->
        Friends.list_pending_requests(user.id)
      end)

    if connected?(socket) do
      # Subscribe to friend request notifications and incoming calls
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}")

      # Trigger async data loading for non-cached data
      send(self(), :load_friends_data)
    end

    {:ok,
     socket
     |> assign(:page_title, "Friends")
     |> assign(:friends, cached_friends)
     |> assign(:pending_requests, cached_pending)
     |> assign(:sent_requests, [])
     |> assign(:suggested_friends, [])
     |> assign(:blocked_users, [])
     |> assign(:pending_follow_requests, [])
     |> assign(:friend_follow_status, %{})
     |> assign(:current_tab, "friends")
     |> assign(:search_query, "")
     |> assign(:friend_request_message, "")
     |> assign(:show_unfriend_modal, false)
     |> assign(:unfriend_user, nil)
     |> assign(
       :loading_friends,
       !Enum.empty?(cached_friends) || !Enum.empty?(cached_pending) ||
         Friends.user_has_any_friend_data?(user.id)
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Read tab from URL params, default to "friends"
    tab = params["tab"] || "friends"

    {:noreply, assign(socket, :current_tab, tab)}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    # Use push_patch to update URL so browser back button works
    # Clear search when changing tabs
    {:noreply,
     socket
     |> assign(:search_query, "")
     |> push_patch(to: ~p"/friends?tab=#{tab}")}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :search_query, String.trim(query))}
  end

  @impl true
  def handle_event("clear_search", _params, socket) do
    {:noreply, assign(socket, :search_query, "")}
  end

  @impl true
  def handle_event("send_friend_request", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)

    message =
      if socket.assigns.friend_request_message != "",
        do: socket.assigns.friend_request_message,
        else: nil

    case Friends.send_friend_request(socket.assigns.current_user.id, user_id, message) do
      {:ok, request} ->
        # Notify recipient via PubSub
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{user_id}",
          {:friend_request_received, request}
        )

        # Refresh suggested friends
        suggested_friends = Friends.get_suggested_friends(socket.assigns.current_user.id, 20)
        sent_requests = Friends.list_sent_requests(socket.assigns.current_user.id)

        socket =
          socket
          |> assign(:suggested_friends, suggested_friends)
          |> assign(:sent_requests, sent_requests)
          |> assign(:friend_request_message, "")
          |> notify_info("Friend request sent")

        {:noreply, socket}

      {:error, :request_already_exists} ->
        {:noreply, notify_error(socket, "A friend request already exists with this user")}

      {:error, reason} ->
        error_message = Elektrine.Privacy.privacy_error_message(reason)
        {:noreply, notify_error(socket, error_message)}
    end
  end

  @impl true
  def handle_event("accept_request", %{"request_id" => request_id}, socket) do
    request_id = String.to_integer(request_id)

    case Friends.accept_friend_request(request_id, socket.assigns.current_user.id) do
      {:ok, request} ->
        # Notify requester via PubSub
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{request.requester_id}",
          {:friend_request_accepted, request}
        )

        # Refresh lists
        friends = Friends.list_friends(socket.assigns.current_user.id)
        pending_requests = Friends.list_pending_requests(socket.assigns.current_user.id)

        socket =
          socket
          |> assign(:friends, friends)
          |> assign(:pending_requests, pending_requests)
          |> notify_info("Friend request accepted")

        {:noreply, socket}

      {:error, :privacy_settings_changed} ->
        # Refresh lists to remove the auto-rejected request
        pending_requests = Friends.list_pending_requests(socket.assigns.current_user.id)

        {:noreply,
         socket
         |> assign(:pending_requests, pending_requests)
         |> notify_error(Elektrine.Privacy.privacy_error_message(:privacy_settings_changed))}

      {:error, reason} ->
        error_message = Elektrine.Privacy.privacy_error_message(reason)
        {:noreply, notify_error(socket, error_message)}
    end
  end

  @impl true
  def handle_event("accept_follow_request", %{"follow-id" => follow_id}, socket) do
    follow_id = String.to_integer(follow_id)

    # Get the follow record
    follow = Elektrine.Repo.get(Elektrine.Profiles.Follow, follow_id)

    if follow && follow.followed_id == socket.assigns.current_user.id do
      # Accept the follow
      Elektrine.Profiles.accept_follow_request(follow_id)

      # Get remote actor and user for sending Accept activity
      remote_actor = Elektrine.Repo.get(Elektrine.ActivityPub.Actor, follow.remote_actor_id)
      user = socket.assigns.current_user

      # Send Accept activity
      accept_activity =
        Elektrine.ActivityPub.Builder.build_accept_activity(user, %{
          "id" => follow.activitypub_id,
          "type" => "Follow",
          "actor" => remote_actor.uri,
          "object" => "#{Elektrine.ActivityPub.instance_url()}/users/#{user.username}"
        })

      Elektrine.ActivityPub.Publisher.publish(accept_activity, user, [remote_actor.inbox_url])

      # Refresh pending requests
      pending_follow_requests = Elektrine.Profiles.get_pending_follow_requests(user.id)

      {:noreply,
       socket
       |> assign(:pending_follow_requests, pending_follow_requests)
       |> put_flash(
         :info,
         "Accepted follow request from @#{remote_actor.username}@#{remote_actor.domain}"
       )}
    else
      {:noreply, put_flash(socket, :error, "Follow request not found")}
    end
  end

  @impl true
  def handle_event("reject_follow_request", %{"follow-id" => follow_id}, socket) do
    follow_id = String.to_integer(follow_id)

    # Get the follow record
    follow = Elektrine.Repo.get(Elektrine.Profiles.Follow, follow_id)

    if follow && follow.followed_id == socket.assigns.current_user.id do
      # Get remote actor and user for sending Reject activity
      remote_actor = Elektrine.Repo.get(Elektrine.ActivityPub.Actor, follow.remote_actor_id)
      user = socket.assigns.current_user

      # Send Reject activity
      reject_activity =
        Elektrine.ActivityPub.Builder.build_reject_activity(user, %{
          "id" => follow.activitypub_id,
          "type" => "Follow",
          "actor" => remote_actor.uri,
          "object" => "#{Elektrine.ActivityPub.instance_url()}/users/#{user.username}"
        })

      Elektrine.ActivityPub.Publisher.publish(reject_activity, user, [remote_actor.inbox_url])

      # Delete the follow
      Elektrine.Profiles.reject_follow_request(follow_id)

      # Refresh pending requests
      pending_follow_requests = Elektrine.Profiles.get_pending_follow_requests(user.id)

      {:noreply,
       socket
       |> assign(:pending_follow_requests, pending_follow_requests)
       |> put_flash(
         :info,
         "Rejected follow request from @#{remote_actor.username}@#{remote_actor.domain}"
       )}
    else
      {:noreply, put_flash(socket, :error, "Follow request not found")}
    end
  end

  @impl true
  def handle_event("reject_request", %{"request_id" => request_id}, socket) do
    request_id = String.to_integer(request_id)

    case Friends.reject_friend_request(request_id, socket.assigns.current_user.id) do
      {:ok, _request} ->
        # Refresh pending requests
        pending_requests = Friends.list_pending_requests(socket.assigns.current_user.id)

        socket =
          socket
          |> assign(:pending_requests, pending_requests)
          |> notify_info("Friend request rejected")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to reject request")}
    end
  end

  @impl true
  def handle_event("cancel_request", %{"request_id" => request_id}, socket) do
    request_id = String.to_integer(request_id)

    case Friends.cancel_friend_request(request_id, socket.assigns.current_user.id) do
      {:ok, _} ->
        # Refresh sent requests and suggested
        sent_requests = Friends.list_sent_requests(socket.assigns.current_user.id)
        suggested_friends = Friends.get_suggested_friends(socket.assigns.current_user.id, 20)

        socket =
          socket
          |> assign(:sent_requests, sent_requests)
          |> assign(:suggested_friends, suggested_friends)
          |> notify_info("Friend request cancelled")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to cancel request")}
    end
  end

  @impl true
  def handle_event("start_dm", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)

    # Create DM conversation (returns existing if already exists)
    case Elektrine.Messaging.create_dm_conversation(socket.assigns.current_user.id, user_id) do
      {:ok, conversation} ->
        {:noreply, push_navigate(socket, to: ~p"/chat/#{conversation.hash}")}

      {:error, :rate_limited} ->
        {:noreply,
         notify_error(
           socket,
           "You are creating too many conversations. Please wait a moment and try again."
         )}

      {:error, reason} ->
        error_message = Elektrine.Privacy.privacy_error_message(reason)
        {:noreply, notify_error(socket, error_message)}
    end
  end

  @impl true
  def handle_event("initiate_call", %{"user_id" => user_id, "call_type" => _call_type}, socket) do
    user_id = String.to_integer(user_id)

    # Create DM conversation and navigate to it
    # User will click call button from chat
    case Elektrine.Messaging.create_dm_conversation(socket.assigns.current_user.id, user_id) do
      {:ok, conversation} ->
        {:noreply, push_navigate(socket, to: ~p"/chat/#{conversation.hash}")}

      {:error, :rate_limited} ->
        {:noreply,
         notify_error(
           socket,
           "You are creating too many conversations. Please wait a moment and try again."
         )}

      {:error, reason} ->
        error_message = Elektrine.Privacy.privacy_error_message(reason)
        {:noreply, notify_error(socket, error_message)}
    end
  end

  @impl true
  def handle_event("show_unfriend_modal", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)
    user = Enum.find(socket.assigns.friends, &(&1.id == user_id))

    socket =
      socket
      |> assign(:show_unfriend_modal, true)
      |> assign(:unfriend_user, user)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_unfriend", _params, socket) do
    socket =
      socket
      |> assign(:show_unfriend_modal, false)
      |> assign(:unfriend_user, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("confirm_unfriend", _params, socket) do
    user_id = socket.assigns.unfriend_user.id

    case Friends.unfriend(socket.assigns.current_user.id, user_id) do
      {:ok, _} ->
        # Refresh friends list
        friends = Friends.list_friends(socket.assigns.current_user.id)

        socket =
          socket
          |> assign(:friends, friends)
          |> assign(:show_unfriend_modal, false)
          |> assign(:unfriend_user, nil)
          |> notify_info("Friend removed")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to remove friend")}
    end
  end

  @impl true
  def handle_event("answer_call", %{"call_id" => call_id}, socket) do
    # Navigate to chat to handle the call
    call = Elektrine.Calls.get_call_with_users(call_id)

    if call do
      # Find or create DM with caller
      caller_id =
        if call.caller_id == socket.assigns.current_user.id,
          do: call.callee_id,
          else: call.caller_id

      case Messaging.create_dm_conversation(socket.assigns.current_user.id, caller_id) do
        {:ok, conversation} ->
          {:noreply,
           push_navigate(socket, to: ~p"/chat/#{conversation.hash}?incoming_call=#{call_id}")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to answer call")}
      end
    else
      {:noreply, notify_error(socket, "Call not found")}
    end
  end

  @impl true
  def handle_event("unblock_user", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)

    case Elektrine.Accounts.unblock_user(socket.assigns.current_user.id, user_id) do
      {:ok, _} ->
        # Refresh blocked users list
        blocked_users = Elektrine.Accounts.list_blocked_users(socket.assigns.current_user.id)

        socket =
          socket
          |> assign(:blocked_users, blocked_users)
          |> notify_info("User unblocked")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to unblock user")}
    end
  end

  # PubSub message handlers

  @impl true
  def handle_info({:friend_request_received, _request}, socket) do
    # Refresh pending requests
    pending_requests = Friends.list_pending_requests(socket.assigns.current_user.id)
    {:noreply, assign(socket, :pending_requests, pending_requests)}
  end

  @impl true
  def handle_info({:friend_request_accepted, _request}, socket) do
    # Refresh friends list
    friends = Friends.list_friends(socket.assigns.current_user.id)
    {:noreply, assign(socket, :friends, friends)}
  end

  # Async data loading handler
  @impl true
  def handle_info(:load_friends_data, socket) do
    user = socket.assigns.current_user

    # Load all data in parallel
    friends_task = Task.async(fn -> Friends.list_friends(user.id) end)
    pending_task = Task.async(fn -> Friends.list_pending_requests(user.id) end)
    sent_task = Task.async(fn -> Friends.list_sent_requests(user.id) end)
    suggested_task = Task.async(fn -> Friends.get_suggested_friends(user.id, 20) end)
    blocked_task = Task.async(fn -> Elektrine.Accounts.list_blocked_users(user.id) end)

    follow_requests_task =
      Task.async(fn -> Elektrine.Profiles.get_pending_follow_requests(user.id) end)

    friends = Task.await(friends_task, 5000)
    pending_requests = Task.await(pending_task, 5000)
    sent_requests = Task.await(sent_task, 5000)
    suggested_friends = Task.await(suggested_task, 5000)
    blocked_users = Task.await(blocked_task, 5000)
    pending_follow_requests = Task.await(follow_requests_task, 5000)

    # Get follow status for each friend
    friend_follow_status =
      friends
      |> Enum.map(fn friend ->
        {friend.id, Friends.get_relationship_status(user.id, friend.id)}
      end)
      |> Map.new()

    {:noreply,
     socket
     |> assign(:friends, friends)
     |> assign(:pending_requests, pending_requests)
     |> assign(:sent_requests, sent_requests)
     |> assign(:suggested_friends, suggested_friends)
     |> assign(:blocked_users, blocked_users)
     |> assign(:pending_follow_requests, pending_follow_requests)
     |> assign(:friend_follow_status, friend_follow_status)
     |> assign(:loading_friends, false)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end
end
