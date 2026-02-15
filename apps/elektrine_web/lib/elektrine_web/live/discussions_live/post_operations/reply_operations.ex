defmodule ElektrineWeb.DiscussionsLive.PostOperations.ReplyOperations do
  @moduledoc """
  Handles reply-related operations for discussion post detail view.
  """

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  alias Elektrine.Messaging

  def handle_event("toggle_reply_form", _params, socket) do
    if socket.assigns.current_user do
      {:noreply, assign(socket, :show_reply_form, !socket.assigns.show_reply_form)}
    else
      {:noreply, notify_error(socket, "You must be signed in to reply")}
    end
  end

  def handle_event("create_reply", %{"content" => content}, socket) do
    if socket.assigns.current_user do
      community = socket.assigns.community
      user_id = socket.assigns.current_user.id

      cond do
        Map.get(socket.assigns.post, :locked_at) ->
          {:noreply, notify_error(socket, "This thread is locked and cannot receive new replies")}

        !community.is_public && !is_member?(community.id, user_id) ->
          {:noreply, notify_error(socket, "You must be a member of this community to reply")}

        String.trim(content) == "" ->
          {:noreply, notify_error(socket, "Reply cannot be empty")}

        true ->
          case Messaging.create_text_message(
                 socket.assigns.community.id,
                 socket.assigns.current_user.id,
                 content,
                 socket.assigns.post.id
               ) do
            {:ok, _reply_message} ->
              {:ok, _post, updated_replies} =
                get_post_with_replies_expanded(
                  socket.assigns.post.id,
                  socket.assigns.community.id,
                  socket.assigns.expanded_threads
                )

              {:noreply,
               socket
               |> assign(:reply_content, "")
               |> assign(:show_reply_form, false)
               |> assign(:replies, updated_replies)
               |> notify_info("Reply posted!")}

            {:error, _} ->
              {:noreply, notify_error(socket, "Failed to post reply")}
          end
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to reply")}
    end
  end

  def handle_event("update_reply_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, :reply_content, content)}
  end

  def handle_event("show_nested_reply_form", %{"message_id" => message_id}, socket) do
    if socket.assigns.current_user do
      message_id = String.to_integer(message_id)
      {:noreply, assign(socket, :nested_reply_to, message_id)}
    else
      {:noreply, notify_error(socket, "You must be signed in to reply")}
    end
  end

  def handle_event("cancel_nested_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:nested_reply_to, nil)
     |> assign(:nested_reply_content, "")}
  end

  def handle_event(
        "create_nested_reply",
        %{"content" => content, "reply_to_id" => reply_to_id},
        socket
      ) do
    if socket.assigns.current_user do
      community = socket.assigns.community
      user_id = socket.assigns.current_user.id

      cond do
        !community.is_public && !is_member?(community.id, user_id) ->
          {:noreply, notify_error(socket, "You must be a member of this community to reply")}

        String.trim(content) == "" ->
          {:noreply, notify_error(socket, "Reply cannot be empty")}

        true ->
          reply_to_id = String.to_integer(reply_to_id)

          case Messaging.create_text_message(
                 socket.assigns.community.id,
                 socket.assigns.current_user.id,
                 content,
                 reply_to_id
               ) do
            {:ok, _reply_message} ->
              {:ok, _post, updated_replies} =
                get_post_with_replies_expanded(
                  socket.assigns.post.id,
                  socket.assigns.community.id,
                  socket.assigns.expanded_threads
                )

              {:noreply,
               socket
               |> assign(:nested_reply_content, "")
               |> assign(:nested_reply_to, nil)
               |> assign(:replies, updated_replies)
               |> notify_info("Reply posted!")}

            {:error, _} ->
              {:noreply, notify_error(socket, "Failed to post reply")}
          end
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to reply")}
    end
  end

  def handle_event("update_nested_reply_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, :nested_reply_content, content)}
  end

  def handle_event("load_more_replies", %{"parent_id" => parent_id}, socket) do
    parent_id = String.to_integer(parent_id)
    expanded_threads = MapSet.put(socket.assigns.expanded_threads, parent_id)

    {:ok, _post, updated_replies} =
      get_post_with_replies_expanded(
        socket.assigns.post.id,
        socket.assigns.community.id,
        expanded_threads
      )

    {:noreply,
     socket
     |> assign(:replies, updated_replies)
     |> assign(:expanded_threads, expanded_threads)}
  end

  # Helper functions

  defp is_member?(community_id, user_id) do
    import Ecto.Query

    Elektrine.Repo.exists?(
      from m in Elektrine.Messaging.ConversationMember,
        where: m.conversation_id == ^community_id and m.user_id == ^user_id
    )
  end

  defp get_post_with_replies_expanded(post_id, community_id, expanded_threads) do
    import Ecto.Query

    post =
      from(m in Elektrine.Messaging.Message,
        where: m.id == ^post_id and m.conversation_id == ^community_id,
        preload: [
          sender: [:profile],
          link_preview: [],
          flair: [],
          shared_message: [sender: [:profile], conversation: []],
          poll: [options: []]
        ]
      )
      |> Elektrine.Repo.one()

    case post do
      nil ->
        {:error, :not_found}

      post ->
        post = Elektrine.Messaging.Message.decrypt_content(post)
        replies = get_threaded_replies_with_expansion(post_id, community_id, 0, expanded_threads)
        {:ok, post, replies}
    end
  end

  defp get_threaded_replies_with_expansion(parent_id, community_id, depth, expanded_threads) do
    import Ecto.Query

    direct_replies =
      from(m in Elektrine.Messaging.Message,
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
      |> Elektrine.Repo.all()
      |> Enum.map(&Elektrine.Messaging.Message.decrypt_content/1)

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
