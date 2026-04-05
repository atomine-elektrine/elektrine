defmodule ElektrineSocialWeb.TimelineLive.Operations.ReplyOperations do
  @moduledoc """
  Reply operations for the timeline live view.
  Handles showing reply forms, creating replies, and viewing original context.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Fetcher
  alias Elektrine.Messaging.Message
  alias Elektrine.Social
  alias Elektrine.Utils.SafeConvert
  alias ElektrineSocialWeb.TimelineLive.Operations.Helpers
  alias ElektrineWeb.Live.PostInteractions

  # Shows the reply form for a post.
  def handle_event("show_reply_form", %{"message_id" => message_id}, socket) do
    case SafeConvert.parse_id(message_id) do
      {:ok, message_id} ->
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

          recent_replies = recent_replies_for_post(socket, message_id, reply_to_post)

          updated_socket =
            socket
            |> assign(:reply_to_post, reply_to_post)
            |> assign(:reply_to_post_recent_replies, recent_replies)
            |> assign(:reply_to_reply_id, nil)
            |> maybe_fetch_remote_replies_preview(message_id, reply_to_post, recent_replies)
            |> Helpers.touch_filtered_posts(
              Enum.reject(
                [current_reply && current_reply.id, message_id],
                &is_nil/1
              )
            )
            |> push_event("focus_reply_form", %{
              textarea_id: "reply-textarea-#{message_id}",
              container_id: "reply-form-#{message_id}"
            })

          {:noreply, updated_socket}
        end

      {:error, :invalid_id} ->
        {:noreply, socket}
    end
  end

  # Cancels the reply form and clears reply state.
  def handle_event("cancel_reply", _params, socket) do
    {:noreply,
     socket
     |> assign(:reply_to_post, nil)
     |> assign(:reply_to_post_recent_replies, [])
     |> assign(:reply_to_reply_id, nil)
     |> assign(:reply_content, "")
     |> Helpers.touch_filtered_posts(
       socket.assigns.reply_to_post && socket.assigns.reply_to_post.id
     )}
  end

  # Shows the reply form for replying to a reply.
  def handle_event(
        "show_reply_to_reply_form",
        %{"reply_id" => reply_id, "post_id" => post_id},
        socket
      ) do
    case SafeConvert.parse_id(post_id) do
      {:ok, post_id} ->
        reply_to_post = Enum.find(socket.assigns.timeline_posts, &(&1.id == post_id))
        normalized_reply_id = normalize_reply_target_id(reply_id)

        {:noreply,
         socket
         |> assign(:reply_to_reply_id, normalized_reply_id)
         |> assign(:reply_to_post, reply_to_post)
         |> assign(
           :reply_to_post_recent_replies,
           recent_replies_for_post(socket, post_id, reply_to_post)
         )
         |> assign(:reply_content, "")
         |> Helpers.touch_filtered_posts(post_id)}

      {:error, :invalid_id} ->
        {:noreply, socket}
    end
  end

  # Creates a reply to a timeline post or another reply.
  def handle_event(
        "create_timeline_reply",
        %{"content" => content, "reply_to_id" => reply_to_id},
        socket
      ) do
    if Elektrine.Strings.present?(content) do
      user = socket.assigns.current_user

      case resolve_parent_for_reply(socket, reply_to_id) do
        {:ok, %{parent_id: parent_id, parent: parent}} ->
          reply_visibility =
            (parent && parent.visibility) || user.default_post_visibility || "public"

          case Social.create_timeline_post(
                 user.id,
                 content,
                 visibility: reply_visibility,
                 reply_to_id: parent_id
               ) do
            {:ok, _updated_reply} ->
              Social.increment_reply_count(parent_id)

              Task.start(fn ->
                Elektrine.Accounts.TrustLevel.increment_stat(user.id, :replies_created)

                if parent && !parent.federated && parent.sender_id && parent.sender_id != user.id do
                  Elektrine.Accounts.TrustLevel.increment_stat(
                    parent.sender_id,
                    :replies_received
                  )
                end
              end)

              root_post_id = resolve_root_post_id(parent_id, socket)

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

        {:error, :invalid_reply_target} ->
          {:noreply, put_flash(socket, :error, "Reply target is no longer available")}
      end
    else
      {:noreply, put_flash(socket, :error, "Reply cannot be empty")}
    end
  end

  # Updates the reply content as the user types.
  def handle_event("update_reply_content", %{"value" => content}, socket) do
    {:noreply, update_reply_content(socket, content)}
  end

  def handle_event("update_reply_content", %{"content" => content}, socket) do
    {:noreply, update_reply_content(socket, content)}
  end

  def handle_event("load_remote_replies", %{"post_id" => post_id}, socket) do
    case SafeConvert.parse_id(post_id) do
      {:ok, normalized_post_id} ->
        loading_set = socket.assigns[:loading_remote_replies] || MapSet.new()

        if MapSet.member?(loading_set, normalized_post_id) do
          {:noreply, socket}
        else
          send(self(), {:refresh_remote_replies, normalized_post_id, 1})

          manual_loading_set = socket.assigns[:manual_loading_remote_replies] || MapSet.new()

          {:noreply,
           socket
           |> assign(:loading_remote_replies, MapSet.put(loading_set, normalized_post_id))
           |> assign(
             :manual_loading_remote_replies,
             MapSet.put(manual_loading_set, normalized_post_id)
           )
           |> Helpers.touch_filtered_posts(normalized_post_id)}
        end

      {:error, :invalid_id} ->
        {:noreply, socket}
    end
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

  defp recent_replies_for_post(socket, message_id, reply_to_post) do
    loaded_replies =
      socket.assigns.post_replies
      |> Map.get(message_id, [])

    db_replies =
      if reply_to_post do
        query_recent_replies(message_id)
      else
        []
      end

    (loaded_replies ++ db_replies)
    |> Enum.uniq_by(&reply_identity_key/1)
    |> Enum.sort_by(&reply_inserted_at_unix/1, :desc)
    |> Enum.take(3)
    |> Enum.reverse()
  end

  defp update_reply_content(socket, content) do
    socket
    |> assign(:reply_content, content)
    |> Helpers.touch_filtered_posts(
      socket.assigns.reply_to_post && socket.assigns.reply_to_post.id
    )
  end

  defp query_recent_replies(message_id) do
    import Ecto.Query

    from(m in Message,
      where: m.reply_to_id == ^message_id and is_nil(m.deleted_at),
      order_by: [desc: m.inserted_at],
      limit: 3,
      preload: [sender: [:profile], remote_actor: []]
    )
    |> Elektrine.Repo.all()
  end

  defp maybe_fetch_remote_replies_preview(socket, post_id, reply_to_post, recent_replies) do
    loading_set = socket.assigns[:loading_remote_replies] || MapSet.new()

    cond do
      !is_map(reply_to_post) ->
        socket

      reply_to_post.federated != true ->
        socket

      !Elektrine.Strings.present?(reply_to_post.activitypub_id) ->
        socket

      recent_replies != [] ->
        socket

      MapSet.member?(loading_set, post_id) ->
        socket

      true ->
        parent = self()
        activitypub_id = reply_to_post.activitypub_id

        Task.start(fn ->
          remote_replies = fetch_remote_replies_for_preview(activitypub_id)
          send(parent, {:remote_replies_loaded, post_id, remote_replies})
        end)

        assign(socket, :loading_remote_replies, MapSet.put(loading_set, post_id))
    end
  end

  defp fetch_remote_replies_for_preview(activitypub_id) do
    with {:ok, post_object} <- Fetcher.fetch_object(activitypub_id),
         {:ok, replies} when is_list(replies) <-
           ActivityPub.fetch_remote_post_replies(post_object, limit: 3) do
      replies
    else
      _ -> []
    end
  end

  defp reply_identity_key(reply) do
    Map.get(reply, :id) ||
      Map.get(reply, :activitypub_id) ||
      Map.get(reply, :ap_id) ||
      {Map.get(reply, :content), Map.get(reply, :inserted_at)}
  end

  defp reply_inserted_at_unix(reply) do
    case Map.get(reply, :inserted_at) do
      %DateTime{} = dt ->
        DateTime.to_unix(dt)

      %NaiveDateTime{} = naive ->
        naive
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.to_unix()

      _ ->
        0
    end
  end

  defp normalize_reply_target_id(value) when is_integer(value), do: value

  defp normalize_reply_target_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    case Integer.parse(trimmed) do
      {id, ""} -> id
      _ -> trimmed
    end
  end

  defp normalize_reply_target_id(_), do: nil

  defp resolve_parent_for_reply(socket, reply_to_id) do
    normalized_id = normalize_reply_target_id(reply_to_id)

    parent_post =
      case normalized_id do
        id when is_integer(id) ->
          Enum.find(socket.assigns.timeline_posts, &(&1.id == id))

        _ ->
          nil
      end

    parent_reply = if parent_post, do: nil, else: find_parent_reply(socket, normalized_id)

    cond do
      parent_post ->
        {:ok, %{parent_id: parent_post.id, parent: parent_post}}

      parent_reply && is_integer(Map.get(parent_reply, :id)) ->
        {:ok, %{parent_id: parent_reply.id, parent: parent_reply}}

      is_integer(normalized_id) or is_binary(normalized_id) ->
        case PostInteractions.resolve_message_for_interaction(normalized_id) do
          {:ok, parent_message} ->
            {:ok, %{parent_id: parent_message.id, parent: parent_message}}

          {:error, _} ->
            {:error, :invalid_reply_target}
        end

      true ->
        {:error, :invalid_reply_target}
    end
  end

  defp find_parent_reply(socket, target_id) do
    socket.assigns.post_replies
    |> Map.values()
    |> List.flatten()
    |> Enum.find(&matches_reply_target?(&1, target_id))
  end

  defp matches_reply_target?(reply, target_id) when is_integer(target_id) do
    Map.get(reply, :id) == target_id
  end

  defp matches_reply_target?(reply, target_id) when is_binary(target_id) do
    values =
      [
        Map.get(reply, :id),
        Map.get(reply, :activitypub_id),
        Map.get(reply, :ap_id)
      ]
      |> Enum.filter(&(&1 != nil))
      |> Enum.map(&to_string/1)

    target_id in values
  end

  defp matches_reply_target?(_reply, _target_id), do: false

  defp resolve_root_post_id(parent_id, socket) do
    root_from_chain = find_thread_root_id(parent_id)

    case socket.assigns.reply_to_post do
      %{id: socket_root_id} when is_integer(socket_root_id) ->
        socket_root_id

      _ ->
        root_from_chain
    end
  end

  defp find_thread_root_id(parent_id) when is_integer(parent_id) do
    find_thread_root_id(parent_id, MapSet.new())
  end

  defp find_thread_root_id(parent_id), do: parent_id

  defp find_thread_root_id(parent_id, visited) do
    import Ecto.Query

    if MapSet.member?(visited, parent_id) do
      parent_id
    else
      parent_reply_to_id =
        from(m in Message, where: m.id == ^parent_id, select: m.reply_to_id)
        |> Elektrine.Repo.one()

      case parent_reply_to_id do
        nil -> parent_id
        next_parent_id -> find_thread_root_id(next_parent_id, MapSet.put(visited, parent_id))
      end
    end
  end
end
