defmodule ElektrineWeb.TimelineLive.Operations.ReplyOperations do
  @moduledoc """
  Reply operations for the timeline live view.
  Handles showing reply forms, creating replies, and viewing original context.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.Social
  alias ElektrineWeb.TimelineLive.Operations.Helpers

  # Shows the reply form for a post.
  def handle_event("show_reply_form", %{"message_id" => message_id}, socket) do
    message_id = String.to_integer(message_id)
    current_reply = socket.assigns.reply_to_post

    if current_reply && current_reply.id == message_id do
      {:noreply,
       push_event(socket, "focus_reply_form", %{
         textarea_id: "reply-textarea-#{message_id}",
         container_id: "reply-form-#{message_id}"
       })}
    else
      reply_to_post = Enum.find(socket.assigns.timeline_posts, &(&1.id == message_id))

      reply_to_post =
        if reply_to_post && reply_to_post.federated do
          Elektrine.Repo.preload(reply_to_post, :remote_actor, force: true)
        else
          reply_to_post
        end

      recent_replies =
        if reply_to_post do
          import Ecto.Query

          from(m in Elektrine.Messaging.Message,
            where: m.reply_to_id == ^message_id and is_nil(m.deleted_at),
            order_by: [desc: m.inserted_at],
            limit: 3,
            preload: [sender: [:profile], remote_actor: []]
          )
          |> Elektrine.Repo.all()
          |> Enum.reverse()
        else
          []
        end

      {:noreply,
       socket
       |> assign(:reply_to_post, reply_to_post)
       |> assign(:reply_to_post_recent_replies, recent_replies)
       |> push_event("focus_reply_form", %{
         textarea_id: "reply-textarea-#{message_id}",
         container_id: "reply-form-#{message_id}"
       })}
    end
  end

  # Cancels the reply form and clears reply state.
  def handle_event("cancel_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:reply_to_post, nil)
     |> assign(:reply_to_post_recent_replies, [])
     |> assign(:reply_to_reply_id, nil)
     |> assign(:reply_content, "")}
  end

  # Shows the reply form for replying to a reply.
  def handle_event(
        "show_reply_to_reply_form",
        %{"reply_id" => reply_id, "post_id" => post_id},
        socket
      ) do
    reply_id = String.to_integer(reply_id)
    post_id = String.to_integer(post_id)

    {:noreply,
     socket
     |> assign(:reply_to_reply_id, reply_id)
     |> assign(:reply_to_post, Enum.find(socket.assigns.timeline_posts, &(&1.id == post_id)))
     |> assign(:reply_content, "")}
  end

  # Creates a reply to a timeline post or another reply.
  def handle_event(
        "create_timeline_reply",
        %{"content" => content, "reply_to_id" => reply_to_id},
        socket
      ) do
    if String.trim(content) == "" do
      {:noreply, put_flash(socket, :error, "Reply cannot be empty")}
    else
      reply_to_id = String.to_integer(reply_to_id)
      user = socket.assigns.current_user

      parent_post = Enum.find(socket.assigns.timeline_posts, &(&1.id == reply_to_id))

      parent_reply =
        if !parent_post do
          socket.assigns.post_replies
          |> Map.values()
          |> List.flatten()
          |> Enum.find(&(&1.id == reply_to_id))
        else
          nil
        end

      parent = parent_post || parent_reply
      reply_visibility = (parent && parent.visibility) || user.default_post_visibility || "public"

      case Social.create_timeline_post(
             user.id,
             content,
             visibility: reply_visibility,
             reply_to_id: reply_to_id
           ) do
        {:ok, _updated_reply} ->
          Social.increment_reply_count(reply_to_id)

          Task.start(fn ->
            Elektrine.Accounts.TrustLevel.increment_stat(user.id, :replies_created)

            if parent && !parent.federated && parent.sender_id && parent.sender_id != user.id do
              Elektrine.Accounts.TrustLevel.increment_stat(parent.sender_id, :replies_received)
            end
          end)

          root_post_id =
            if parent_post do
              parent_post.id
            else
              parent_reply.reply_to_id || socket.assigns.reply_to_post.id
            end

          updated_posts =
            Enum.map(socket.assigns.timeline_posts, fn post ->
              if post.id == root_post_id do
                %{post | reply_count: (post.reply_count || 0) + 1}
              else
                post
              end
            end)

          reloaded_replies =
            Social.get_direct_replies_for_posts([root_post_id],
              user_id: user.id,
              limit_per_post: 3
            )

          updated_post_replies = Map.merge(socket.assigns.post_replies, reloaded_replies)

          updated_socket =
            socket
            |> assign(:reply_content, "")
            |> assign(:reply_to_post, nil)
            |> assign(:reply_to_reply_id, nil)
            |> assign(:reply_to_post_recent_replies, [])
            |> assign(:timeline_posts, updated_posts)
            |> assign(:post_replies, updated_post_replies)
            |> Helpers.apply_timeline_filter()

          {:noreply, put_flash(updated_socket, :info, "Reply posted!")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to post reply")}
      end
    end
  end

  # Updates the reply content as the user types.
  def handle_event("update_reply_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, :reply_content, content)}
  end

  # Navigates to the original context of a cross-posted message.
  def handle_event("view_original_context", %{"message_id" => original_message_id}, socket) do
    original_message_id = String.to_integer(original_message_id)

    case Elektrine.Repo.get(Elektrine.Messaging.Message, original_message_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Original content not found")}

      message ->
        message = Elektrine.Repo.preload(message, :conversation)

        case message.conversation.type do
          "timeline" ->
            {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{message.id}")}

          "community" ->
            {:noreply,
             push_navigate(socket,
               to: ~p"/communities/#{message.conversation.name}/post/#{message.id}"
             )}

          _ ->
            {:noreply,
             push_navigate(socket,
               to: ~p"/chat/#{message.conversation.hash || message.conversation.id}"
             )}
        end
    end
  end

  # Loads remote replies for a federated post
  def handle_event(
        "load_remote_replies",
        %{"post_id" => post_id, "activitypub_id" => _activitypub_id},
        socket
      ) do
    post_id = String.to_integer(post_id)

    # Set loading state
    loading_set = MapSet.put(socket.assigns.loading_remote_replies, post_id)
    socket = assign(socket, :loading_remote_replies, loading_set)

    user_id = socket.assigns[:current_user] && socket.assigns.current_user.id

    local_replies =
      if user_id do
        Social.get_direct_replies_for_posts([post_id], user_id: user_id, limit_per_post: 20)
        |> Map.get(post_id, [])
      else
        Social.get_direct_replies_for_posts([post_id], limit_per_post: 20)
        |> Map.get(post_id, [])
      end

    if local_replies == [] do
      _ = Elektrine.ActivityPub.RepliesIngestWorker.enqueue(post_id)
    end

    send(self(), {:post_replies_loaded, post_id, local_replies})

    {:noreply, socket}
  end
end
