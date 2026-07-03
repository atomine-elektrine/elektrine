defmodule ElektrineSocialWeb.RemoteUserLive.ReplyOperations do
  @moduledoc """
  Reply form events for the remote user profile LiveView.
  """

  import Phoenix.Component
  import Phoenix.LiveView, only: [put_flash: 3]

  alias ElektrineSocialWeb.RemoteUserLive.PostState
  alias ElektrineSocialWeb.RemoteUserLive.TimelineLoader

  def handle_event("show_reply_form", %{"post_id" => post_id}, socket) do
    normalized_post_id = PostState.normalize_post_id_for_reply(socket, post_id)

    # First check timeline_posts (remote/outbox posts - maps with string keys)
    timeline_post =
      Enum.find(socket.assigns.timeline_posts, fn p -> p["id"] == normalized_post_id end)

    # If not found, check local_posts (Ecto schemas)
    local_post =
      Enum.find(socket.assigns.local_posts, fn p ->
        (p.activitypub_id || to_string(p.id)) == normalized_post_id
      end)

    reply_to_post =
      cond do
        timeline_post ->
          timeline_post

        local_post ->
          # Store just the normalized post_id for local posts since we need it for reply
          normalized_post_id

        true ->
          nil
      end

    fetch_target = timeline_post || local_post

    already_has_replies? =
      cond do
        is_nil(fetch_target) ->
          true

        match?(%{__struct__: _}, fetch_target) ->
          PostState.replies_for_post(fetch_target, socket.assigns.post_replies) != []

        is_map(fetch_target) ->
          Map.get(socket.assigns.post_replies || %{}, normalized_post_id, []) != []

        true ->
          true
      end

    if fetch_target && !already_has_replies? do
      TimelineLoader.schedule_replies_fetch([fetch_target], self())
    end

    {:noreply,
     socket
     |> assign(:show_reply_form, true)
     |> assign(:reply_to_post, reply_to_post)
     |> assign(:reply_content, "")}
  end

  def handle_event("show_reply_form", %{"message_id" => message_id}, socket) do
    post_id = PostState.normalize_post_id_for_reply(socket, message_id)
    handle_event("show_reply_form", %{"post_id" => post_id}, socket)
  end

  def handle_event("show_reply_form", %{"id" => id}, socket) do
    post_id = PostState.normalize_post_id_for_reply(socket, id)
    handle_event("show_reply_form", %{"post_id" => post_id}, socket)
  end

  def handle_event("cancel_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reply_form, false)
     |> assign(:reply_to_post, nil)
     |> assign(:reply_content, "")}
  end

  def handle_event("update_reply_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, :reply_content, content)}
  end

  def handle_event("update_reply_content", %{"value" => content}, socket) do
    {:noreply, assign(socket, :reply_content, content)}
  end

  def handle_event("submit_reply", _params, socket) do
    if PostState.current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to reply")}
    else
      if Elektrine.Strings.present?(socket.assigns.reply_content) do
        user = socket.assigns.current_user
        post = socket.assigns.reply_to_post

        # Handle both remote posts (maps) and local posts (just the post_id string)
        activitypub_id =
          cond do
            is_map(post) -> post["id"]
            is_binary(post) -> post
            true -> nil
          end

        # First, check if this post is already stored locally (we've seen it before)
        local_message = Elektrine.Messaging.get_message_by_activitypub_id(activitypub_id)

        reply_to_id =
          if local_message do
            local_message.id
          else
            # Post not in our database yet - only try to fetch/store if it's a remote post (map)
            if is_map(post) do
              # Use store_remote_post which handles Create synchronously (bypasses queue)
              case Elektrine.ActivityPub.Handler.store_remote_post(
                     post,
                     socket.assigns.remote_actor.uri
                   ) do
                {:ok, message} when is_struct(message) -> message.id
                # Got raw object back, need message
                {:ok, %{"id" => _}} -> nil
                _ -> nil
              end
            else
              nil
            end
          end

        if reply_to_id do
          # Create reply with the local message id
          case Elektrine.Social.create_timeline_post(
                 user.id,
                 socket.assigns.reply_content,
                 visibility: "public",
                 reply_to_id: reply_to_id
               ) do
            {:ok, _reply} ->
              {:noreply,
               socket
               |> assign(:show_reply_form, false)
               |> assign(:reply_to_post, nil)
               |> assign(:reply_content, "")
               |> put_flash(
                 :info,
                 "Reply posted! It will be federated to #{socket.assigns.remote_actor.domain}"
               )}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to post reply")}
          end
        else
          {:noreply, put_flash(socket, :error, "Failed to process remote post")}
        end
      else
        {:noreply, put_flash(socket, :error, "Reply cannot be empty")}
      end
    end
  end
end
