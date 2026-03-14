defmodule ElektrineWeb.DiscussionsLive.PostOperations.ModerationOperations do
  @moduledoc """
  Handles moderation operations for discussion post detail view.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.Messaging

  def handle_event("delete_post_admin", %{"message_id" => message_id}, socket) do
    if socket.assigns.current_user && socket.assigns.current_user.is_admin do
      message_id = String.to_integer(message_id)

      case Messaging.delete_message(message_id, socket.assigns.current_user.id, true) do
        {:ok, _deleted_message} ->
          community_name = socket.assigns.community.name

          {:noreply,
           socket
           |> notify_info("Discussion deleted successfully")
           |> push_navigate(to: ~p"/communities/#{community_name}")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to delete discussion")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("delete_discussion", %{"message_id" => message_id}, socket) do
    message_id = String.to_integer(message_id)

    if socket.assigns.current_user &&
         socket.assigns.post.sender_id == socket.assigns.current_user.id do
      case Messaging.delete_message(message_id, socket.assigns.current_user.id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> notify_info("Discussion deleted successfully")
           |> push_navigate(to: ~p"/communities/#{socket.assigns.community.name}")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to delete discussion")}
      end
    else
      {:noreply, notify_error(socket, "You can only delete your own discussions")}
    end
  end

  def handle_event("delete_post_mod", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator do
      message_id = String.to_integer(message_id)

      case Messaging.delete_message(message_id, socket.assigns.current_user.id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> notify_info("Post deleted successfully")
           |> push_navigate(to: ~p"/communities/#{socket.assigns.community.name}")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to delete post")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("pin_post", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator do
      message_id = String.to_integer(message_id)

      case Messaging.pin_message(message_id, socket.assigns.current_user.id) do
        {:ok, _pinned_post} ->
          updated_post =
            Elektrine.Repo.get!(Elektrine.Messaging.Message, message_id)
            |> Elektrine.Repo.preload(
              sender: [:profile],
              link_preview: [],
              flair: [],
              shared_message: [sender: [:profile], conversation: []],
              poll: [options: []]
            )
            |> Elektrine.Messaging.Message.decrypt_content()

          {:noreply,
           socket
           |> assign(:post, updated_post)
           |> notify_info("Post pinned successfully")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to pin post")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("unpin_post", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator do
      message_id = String.to_integer(message_id)

      case Messaging.unpin_message(message_id, socket.assigns.current_user.id) do
        {:ok, _unpinned_post} ->
          updated_post =
            Elektrine.Repo.get!(Elektrine.Messaging.Message, message_id)
            |> Elektrine.Repo.preload(
              sender: [:profile],
              link_preview: [],
              flair: [],
              shared_message: [sender: [:profile], conversation: []],
              poll: [options: []]
            )
            |> Elektrine.Messaging.Message.decrypt_content()

          {:noreply,
           socket
           |> assign(:post, updated_post)
           |> notify_info("Post unpinned successfully")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to unpin post")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("delete_reply", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      message_id = String.to_integer(message_id)

      case Messaging.delete_message(message_id, socket.assigns.current_user.id) do
        {:ok, _} ->
          {:ok, _post, updated_replies} =
            get_post_with_replies_expanded(
              socket.assigns.post.id,
              socket.assigns.community.id,
              socket.assigns.expanded_threads
            )

          {:noreply,
           socket
           |> assign(:replies, updated_replies)
           |> notify_info("Reply deleted successfully")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to delete reply")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("lock_thread", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator || socket.assigns.current_user.is_admin do
      message_id = String.to_integer(message_id)

      case Messaging.ModerationTools.lock_thread(
             message_id,
             socket.assigns.current_user.id,
             "Locked by moderator"
           ) do
        {:ok, _} ->
          updated_post =
            Elektrine.Repo.get!(Elektrine.Messaging.Message, message_id)
            |> Elektrine.Repo.preload(
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

          {:noreply,
           socket
           |> assign(:post, updated_post)
           |> notify_info("Thread locked")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to lock thread")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("unlock_thread", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator || socket.assigns.current_user.is_admin do
      message_id = String.to_integer(message_id)

      case Messaging.ModerationTools.unlock_thread(message_id, socket.assigns.current_user.id) do
        {:ok, _} ->
          updated_post =
            Elektrine.Repo.get!(Elektrine.Messaging.Message, message_id)
            |> Elektrine.Repo.preload(
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

          {:noreply,
           socket
           |> assign(:post, updated_post)
           |> notify_info("Thread unlocked")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to unlock thread")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("show_ban_modal", %{"user_id" => user_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(user_id)
      user = Elektrine.Repo.get(Elektrine.Accounts.User, user_id)

      {:noreply,
       socket
       |> assign(:show_ban_modal, true)
       |> assign(:ban_target_user, user)}
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("cancel_ban", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_ban_modal, false)
     |> assign(:ban_target_user, nil)}
  end

  def handle_event("ban_user", params, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(params["user_id"])
      reason = String.trim(params["reason"] || "Banned by moderator")
      duration_days = String.to_integer(params["duration_days"] || "0")

      expires_at =
        if duration_days > 0 do
          DateTime.add(DateTime.utc_now(), duration_days * 24 * 60 * 60, :second)
        else
          nil
        end

      case Messaging.ban_user_from_community(
             socket.assigns.community.id,
             user_id,
             socket.assigns.current_user.id,
             reason,
             expires_at
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:show_ban_modal, false)
           |> assign(:ban_target_user, nil)
           |> notify_info("User banned from community")}

        {:error, :cannot_ban_moderator} ->
          {:noreply, notify_error(socket, "Cannot ban moderators or owners")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to ban user")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("show_warning_modal", params, socket) do
    if socket.assigns.is_moderator || socket.assigns.current_user.is_admin do
      user_id = String.to_integer(params["user_id"])

      message_id =
        case params["message_id"] do
          nil -> nil
          id -> String.to_integer(id)
        end

      user = Elektrine.Repo.get(Elektrine.Accounts.User, user_id)

      {:noreply,
       socket
       |> assign(:show_warning_modal, true)
       |> assign(:warning_target_user, user)
       |> assign(:warning_message_id, message_id)}
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("cancel_warning", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_warning_modal, false)
     |> assign(:warning_target_user, nil)
     |> assign(:warning_message_id, nil)}
  end

  def handle_event("warn_user", params, socket) do
    if socket.assigns.is_moderator || socket.assigns.current_user.is_admin do
      user_id = String.to_integer(params["user_id"])
      reason = String.trim(params["reason"])
      severity = params["severity"] || "low"

      message_id =
        case params["message_id"] do
          "" -> nil
          nil -> nil
          id -> String.to_integer(id)
        end

      case Messaging.ModerationTools.warn_user(
             socket.assigns.community.id,
             user_id,
             socket.assigns.current_user.id,
             reason,
             severity: severity,
             message_id: message_id
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:show_warning_modal, false)
           |> assign(:warning_target_user, nil)
           |> assign(:warning_message_id, nil)
           |> notify_info("Warning issued")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to issue warning")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("show_timeout_modal", %{"user_id" => user_id}, socket) do
    if socket.assigns.is_moderator || socket.assigns.current_user.is_admin do
      user_id = String.to_integer(user_id)
      user = Elektrine.Repo.get(Elektrine.Accounts.User, user_id)

      {:noreply,
       socket
       |> assign(:show_timeout_modal, true)
       |> assign(:timeout_target_user, user)}
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("cancel_timeout", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_timeout_modal, false)
     |> assign(:timeout_target_user, nil)}
  end

  def handle_event("timeout_user", params, socket) do
    if socket.assigns.is_moderator || socket.assigns.current_user.is_admin do
      user_id = String.to_integer(params["user_id"])
      reason = String.trim(params["reason"] || "Timed out by moderator")
      duration_minutes = String.to_integer(params["duration_minutes"])

      case Messaging.ModerationTools.timeout_user(
             socket.assigns.community.id,
             user_id,
             socket.assigns.current_user.id,
             duration_minutes,
             reason
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:show_timeout_modal, false)
           |> assign(:timeout_target_user, nil)
           |> notify_info("User timed out")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to timeout user")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("show_note_modal", %{"user_id" => user_id}, socket) do
    if socket.assigns.is_moderator || socket.assigns.current_user.is_admin do
      user_id = String.to_integer(user_id)
      user = Elektrine.Repo.get(Elektrine.Accounts.User, user_id)
      notes = Messaging.ModerationTools.list_moderator_notes(socket.assigns.community.id, user_id)

      {:noreply,
       socket
       |> assign(:show_note_modal, true)
       |> assign(:note_target_user, user)
       |> assign(:user_notes, Map.put(socket.assigns.user_notes, user_id, notes))}
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("cancel_note", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_note_modal, false)
     |> assign(:note_target_user, nil)}
  end

  def handle_event("add_moderator_note", params, socket) do
    if socket.assigns.is_moderator || socket.assigns.current_user.is_admin do
      user_id = String.to_integer(params["user_id"])
      note_text = String.trim(params["note"])
      is_important = params["is_important"] == "on"

      case Messaging.ModerationTools.add_moderator_note(
             socket.assigns.community.id,
             user_id,
             socket.assigns.current_user.id,
             note_text,
             is_important
           ) do
        {:ok, _} ->
          notes =
            Messaging.ModerationTools.list_moderator_notes(socket.assigns.community.id, user_id)

          {:noreply,
           socket
           |> assign(:user_notes, Map.put(socket.assigns.user_notes, user_id, notes))
           |> notify_info("Note added")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to add note")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("show_user_mod_status", %{"user_id" => user_id}, socket) do
    if socket.assigns.is_moderator || socket.assigns.current_user.is_admin do
      user_id = String.to_integer(user_id)
      user = Elektrine.Repo.get(Elektrine.Accounts.User, user_id)

      ban =
        Messaging.list_community_bans(socket.assigns.community.id)
        |> Enum.find(&(&1.user_id == user_id))

      timeout =
        Elektrine.Repo.get_by(Elektrine.Messaging.UserTimeout,
          conversation_id: socket.assigns.community.id,
          user_id: user_id
        )
        |> case do
          nil -> nil
          t -> if DateTime.compare(t.timeout_until, DateTime.utc_now()) == :gt, do: t, else: nil
        end

      warnings =
        Messaging.ModerationTools.list_user_warnings(socket.assigns.community.id, user_id)

      warning_count =
        Messaging.ModerationTools.count_user_warnings(socket.assigns.community.id, user_id)

      notes = Messaging.ModerationTools.list_moderator_notes(socket.assigns.community.id, user_id)

      mod_data = %{
        ban: ban,
        timeout: timeout,
        warnings: warnings,
        warning_count: warning_count,
        notes: notes
      }

      {:noreply,
       socket
       |> assign(:show_user_mod_status_modal, true)
       |> assign(:mod_status_target_user, user)
       |> assign(:user_mod_data, Map.put(socket.assigns.user_mod_data, user_id, mod_data))}
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("close_user_mod_status", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_user_mod_status_modal, false)
     |> assign(:mod_status_target_user, nil)}
  end

  def handle_event("unban_from_status", %{"user_id" => user_id}, socket) do
    if socket.assigns.is_moderator || socket.assigns.current_user.is_admin do
      user_id = String.to_integer(user_id)

      case Messaging.unban_user_from_community(
             socket.assigns.community.id,
             user_id,
             socket.assigns.current_user.id
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:show_user_mod_status_modal, false)
           |> assign(:mod_status_target_user, nil)
           |> notify_info("User unbanned")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to unban user")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("remove_timeout_from_status", %{"user_id" => user_id}, socket) do
    if socket.assigns.is_moderator || socket.assigns.current_user.is_admin do
      user_id = String.to_integer(user_id)

      case Messaging.ModerationTools.remove_timeout(
             socket.assigns.community.id,
             user_id,
             socket.assigns.current_user.id
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:show_user_mod_status_modal, false)
           |> assign(:mod_status_target_user, nil)
           |> notify_info("Timeout removed")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to remove timeout")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  # Helper function
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
