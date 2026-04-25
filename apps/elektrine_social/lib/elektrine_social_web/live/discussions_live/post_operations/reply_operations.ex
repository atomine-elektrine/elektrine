defmodule ElektrineSocialWeb.DiscussionsLive.PostOperations.ReplyOperations do
  @moduledoc """
  Handles reply-related operations for discussion post detail view.
  """

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  alias Elektrine.Messaging

  @initial_reply_expand_depth 2
  @max_reply_depth 10

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

        !community.is_public && !member?(community.id, user_id) ->
          {:noreply, notify_error(socket, "You must be a member of this community to reply")}

        not Elektrine.Strings.present?(content) ->
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
        Map.get(socket.assigns.post, :locked_at) ->
          {:noreply, notify_error(socket, "This thread is locked and cannot receive new replies")}

        !community.is_public && !member?(community.id, user_id) ->
          {:noreply, notify_error(socket, "You must be a member of this community to reply")}

        not Elektrine.Strings.present?(content) ->
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

  defp member?(community_id, user_id) do
    import Ecto.Query

    Elektrine.Repo.exists?(
      from m in Elektrine.Social.ConversationMember,
        where: m.conversation_id == ^community_id and m.user_id == ^user_id and is_nil(m.left_at)
    )
  end

  defp get_post_with_replies_expanded(post_id, community_id, expanded_threads) do
    import Ecto.Query

    post =
      from(m in Elektrine.Social.Message,
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
        post = Elektrine.Social.Message.decrypt_content(post)
        replies = get_threaded_replies_with_expansion(post_id, community_id, 0, expanded_threads)
        {:ok, post, replies}
    end
  end

  defp get_threaded_replies_with_expansion(parent_id, community_id, _depth, expanded_threads) do
    {replies_by_parent, collapsed_parent_ids} =
      load_visible_reply_tree(
        %{parent_id => 0},
        community_id,
        expanded_threads,
        %{},
        MapSet.new()
      )

    child_counts = load_reply_child_counts(MapSet.to_list(collapsed_parent_ids), community_id)
    build_threaded_reply_nodes(parent_id, replies_by_parent, child_counts, 0)
  end

  defp load_visible_reply_tree(
         parent_depths,
         _community_id,
         _expanded_threads,
         replies_by_parent,
         collapsed_parent_ids
       )
       when map_size(parent_depths) == 0 do
    {replies_by_parent, collapsed_parent_ids}
  end

  defp load_visible_reply_tree(
         parent_depths,
         community_id,
         expanded_threads,
         replies_by_parent,
         collapsed_parent_ids
       ) do
    parent_ids = Map.keys(parent_depths)
    replies = load_direct_replies(parent_ids, community_id)
    grouped = Enum.group_by(replies, & &1.reply_to_id)

    {next_parent_depths, collapsed_parent_ids} =
      Enum.reduce(replies, {%{}, collapsed_parent_ids}, fn reply, {next, collapsed} ->
        depth = Map.fetch!(parent_depths, reply.reply_to_id)

        should_expand =
          depth < @initial_reply_expand_depth || MapSet.member?(expanded_threads, reply.id)

        if should_expand && depth < @max_reply_depth do
          {Map.put(next, reply.id, depth + 1), collapsed}
        else
          {next, MapSet.put(collapsed, reply.id)}
        end
      end)

    replies_by_parent = Map.merge(replies_by_parent, grouped)

    load_visible_reply_tree(
      next_parent_depths,
      community_id,
      expanded_threads,
      replies_by_parent,
      collapsed_parent_ids
    )
  end

  defp load_direct_replies([], _community_id), do: []

  defp load_direct_replies(parent_ids, community_id) do
    import Ecto.Query

    from(m in Elektrine.Social.Message,
      where:
        m.reply_to_id in ^parent_ids and
          m.conversation_id == ^community_id and
          is_nil(m.deleted_at) and
          (m.approval_status == "approved" or is_nil(m.approval_status)),
      order_by: [asc: m.reply_to_id, desc: m.score, asc: m.inserted_at],
      preload: [
        sender: [:profile],
        flair: [],
        shared_message: [sender: [:profile], conversation: []]
      ]
    )
    |> Elektrine.Repo.all()
    |> Enum.map(&Elektrine.Social.Message.decrypt_content/1)
  end

  defp load_reply_child_counts([], _community_id), do: %{}

  defp load_reply_child_counts(parent_ids, community_id) do
    import Ecto.Query

    from(m in Elektrine.Social.Message,
      where:
        m.reply_to_id in ^parent_ids and
          m.conversation_id == ^community_id and
          is_nil(m.deleted_at) and
          (m.approval_status == "approved" or is_nil(m.approval_status)),
      group_by: m.reply_to_id,
      select: {m.reply_to_id, count(m.id)}
    )
    |> Elektrine.Repo.all()
    |> Map.new()
  end

  defp build_threaded_reply_nodes(parent_id, replies_by_parent, child_counts, depth) do
    replies_by_parent
    |> Map.get(parent_id, [])
    |> Enum.map(fn reply ->
      children = build_threaded_reply_nodes(reply.id, replies_by_parent, child_counts, depth + 1)
      hidden_child_count = Map.get(child_counts, reply.id, 0)

      %{
        reply: reply,
        children: children,
        depth: depth,
        has_children: children != [] || hidden_child_count > 0,
        has_more_children: children == [] && hidden_child_count > 0
      }
    end)
  end
end
