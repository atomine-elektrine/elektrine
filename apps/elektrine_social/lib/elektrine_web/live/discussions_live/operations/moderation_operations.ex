defmodule ElektrineWeb.DiscussionsLive.Operations.ModerationOperations do
  @moduledoc """
  Handles all moderation operations: bans, timeouts, warnings, auto-mod, post approval.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  # Import verified routes for ~p sigil
  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.{Messaging, Repo}
  alias ElektrineWeb.DiscussionsLive.Operations.SortHelpers

  @doc "Show ban modal"
  def handle_event("show_ban_modal", %{"user_id" => user_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(user_id)
      user = Repo.get(Elektrine.Accounts.User, user_id)

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
          # Reload banned users list and mod log
          banned_users = Messaging.list_community_bans(socket.assigns.community.id)

          mod_log =
            Elektrine.Messaging.ModerationTools.get_moderation_log(socket.assigns.community.id,
              limit: 50
            )

          {:noreply,
           socket
           |> assign(:banned_users, banned_users)
           |> assign(:mod_log, mod_log)
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

  def handle_event("unban_user", %{"user_id" => user_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(user_id)

      case Messaging.unban_user_from_community(
             socket.assigns.community.id,
             user_id,
             socket.assigns.current_user.id
           ) do
        {:ok, _} ->
          # Reload banned users list
          banned_users = Messaging.list_community_bans(socket.assigns.community.id)

          {:noreply,
           socket
           |> assign(:banned_users, banned_users)
           |> notify_info("User unbanned from community")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to unban user")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("show_warning_modal", params, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(params["user_id"])

      message_id =
        case params["message_id"] do
          nil -> nil
          id -> String.to_integer(id)
        end

      user = Repo.get(Elektrine.Accounts.User, user_id)

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
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(params["user_id"])
      reason = String.trim(params["reason"])
      severity = params["severity"] || "low"

      message_id =
        case params["message_id"] do
          "" -> nil
          nil -> nil
          id -> String.to_integer(id)
        end

      case Elektrine.Messaging.ModerationTools.warn_user(
             socket.assigns.community.id,
             user_id,
             socket.assigns.current_user.id,
             reason,
             severity: severity,
             message_id: message_id
           ) do
        {:ok, _} ->
          # Reload moderation log
          mod_log =
            Elektrine.Messaging.ModerationTools.get_moderation_log(socket.assigns.community.id,
              limit: 50
            )

          {:noreply,
           socket
           |> assign(:show_warning_modal, false)
           |> assign(:warning_target_user, nil)
           |> assign(:warning_message_id, nil)
           |> assign(:mod_log, mod_log)
           |> notify_info("Warning issued")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to issue warning")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("show_timeout_modal", %{"user_id" => user_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(user_id)
      user = Repo.get(Elektrine.Accounts.User, user_id)

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
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(params["user_id"])
      reason = String.trim(params["reason"] || "Timed out by moderator")
      duration_minutes = String.to_integer(params["duration_minutes"])

      case Elektrine.Messaging.ModerationTools.timeout_user(
             socket.assigns.community.id,
             user_id,
             socket.assigns.current_user.id,
             duration_minutes,
             reason
           ) do
        {:ok, _} ->
          # Reload moderation log
          mod_log =
            Elektrine.Messaging.ModerationTools.get_moderation_log(socket.assigns.community.id,
              limit: 50
            )

          {:noreply,
           socket
           |> assign(:show_timeout_modal, false)
           |> assign(:timeout_target_user, nil)
           |> assign(:mod_log, mod_log)
           |> notify_info("User timed out")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to timeout user")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("show_note_modal", %{"user_id" => user_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(user_id)
      user = Repo.get(Elektrine.Accounts.User, user_id)

      notes =
        Elektrine.Messaging.ModerationTools.list_moderator_notes(
          socket.assigns.community.id,
          user_id
        )

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
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(params["user_id"])
      note_text = String.trim(params["note"])
      is_important = params["is_important"] == "on"

      case Elektrine.Messaging.ModerationTools.add_moderator_note(
             socket.assigns.community.id,
             user_id,
             socket.assigns.current_user.id,
             note_text,
             is_important
           ) do
        {:ok, _} ->
          # Reload notes for this user
          notes =
            Elektrine.Messaging.ModerationTools.list_moderator_notes(
              socket.assigns.community.id,
              user_id
            )

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

  def handle_event("approve_post", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      message_id = String.to_integer(message_id)

      case Elektrine.Messaging.ModerationTools.approve_post(
             message_id,
             socket.assigns.current_user.id
           ) do
        {:ok, _} ->
          # Remove from pending queue and add to discussion posts
          pending_posts = Enum.reject(socket.assigns.pending_posts, &(&1.id == message_id))

          # Reload discussion posts to include the newly approved post
          discussion_posts =
            SortHelpers.load_posts(socket.assigns.community.id, socket.assigns.sort_by, limit: 20)

          {:noreply,
           socket
           |> assign(:pending_posts, pending_posts)
           |> assign(:discussion_posts, discussion_posts)
           |> notify_info("Post approved")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to approve post")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("reject_post", %{"message_id" => message_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      message_id = String.to_integer(message_id)

      case Elektrine.Messaging.ModerationTools.reject_post(
             message_id,
             socket.assigns.current_user.id,
             "Rejected by moderator"
           ) do
        {:ok, _} ->
          # Remove from pending queue
          pending_posts = Enum.reject(socket.assigns.pending_posts, &(&1.id == message_id))

          {:noreply,
           socket
           |> assign(:pending_posts, pending_posts)
           |> notify_info("Post rejected")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to reject post")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("new_automod_rule", _params, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      {:noreply, assign(socket, :show_rule_modal, true)}
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("cancel_automod_rule", _params, socket) do
    {:noreply, assign(socket, :show_rule_modal, false)}
  end

  def handle_event("create_automod_rule", params, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      attrs = %{
        conversation_id: socket.assigns.community.id,
        name: params["name"],
        rule_type: params["rule_type"],
        pattern: params["pattern"],
        action: params["action"],
        enabled: true,
        created_by_id: socket.assigns.current_user.id
      }

      case Elektrine.Messaging.ModerationTools.create_auto_mod_rule(attrs) do
        {:ok, _} ->
          rules =
            Elektrine.Messaging.ModerationTools.list_auto_mod_rules(socket.assigns.community.id)

          {:noreply,
           socket
           |> assign(:auto_mod_rules, rules)
           |> assign(:show_rule_modal, false)
           |> notify_info("Auto-mod rule created")}

        {:error, %Ecto.Changeset{} = changeset} ->
          errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

          error_msg =
            errors
            |> Enum.map_join("; ", fn {field, messages} ->
              "#{field}: #{Enum.join(messages, ", ")}"
            end)

          {:noreply, notify_error(socket, "Failed to create rule: #{error_msg}")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to create rule")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("toggle_automod_rule", %{"rule_id" => rule_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      rule = Repo.get!(Elektrine.Messaging.AutoModRule, String.to_integer(rule_id))

      case Elektrine.Messaging.ModerationTools.update_auto_mod_rule(rule, %{
             enabled: !rule.enabled
           }) do
        {:ok, _} ->
          rules =
            Elektrine.Messaging.ModerationTools.list_auto_mod_rules(socket.assigns.community.id)

          {:noreply, assign(socket, :auto_mod_rules, rules)}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to toggle rule")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("delete_automod_rule", %{"rule_id" => rule_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      rule = Repo.get!(Elektrine.Messaging.AutoModRule, String.to_integer(rule_id))

      case Repo.delete(rule) do
        {:ok, _} ->
          rules =
            Elektrine.Messaging.ModerationTools.list_auto_mod_rules(socket.assigns.community.id)

          {:noreply, assign(socket, :auto_mod_rules, rules)}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to delete rule")}
      end
    else
      {:noreply, notify_error(socket, "Unauthorized")}
    end
  end

  def handle_event("show_user_mod_status", %{"user_id" => user_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(user_id)
      user = Repo.get(Elektrine.Accounts.User, user_id)

      # Load all moderation data for this user
      ban =
        Messaging.list_community_bans(socket.assigns.community.id)
        |> Enum.find(&(&1.user_id == user_id))

      timeout =
        Repo.get_by(Elektrine.Messaging.UserTimeout,
          conversation_id: socket.assigns.community.id,
          user_id: user_id
        )
        |> case do
          nil -> nil
          t -> if DateTime.compare(t.timeout_until, DateTime.utc_now()) == :gt, do: t, else: nil
        end

      warnings =
        Elektrine.Messaging.ModerationTools.list_user_warnings(
          socket.assigns.community.id,
          user_id
        )

      warning_count =
        Elektrine.Messaging.ModerationTools.count_user_warnings(
          socket.assigns.community.id,
          user_id
        )

      notes =
        Elektrine.Messaging.ModerationTools.list_moderator_notes(
          socket.assigns.community.id,
          user_id
        )

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
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(user_id)

      case Messaging.unban_user_from_community(
             socket.assigns.community.id,
             user_id,
             socket.assigns.current_user.id
           ) do
        {:ok, _} ->
          # Reload moderation data
          banned_users = Messaging.list_community_bans(socket.assigns.community.id)

          {:noreply,
           socket
           |> assign(:banned_users, banned_users)
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

  # Remove timeout from status modal
  def handle_event("remove_timeout_from_status", %{"user_id" => user_id}, socket) do
    if socket.assigns.is_moderator ||
         (socket.assigns.current_user && socket.assigns.current_user.is_admin) do
      user_id = String.to_integer(user_id)

      case Elektrine.Messaging.ModerationTools.remove_timeout(
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

  # Private helpers

  defp notify_error(socket, message) do
    put_flash(socket, :error, message)
  end

  defp notify_info(socket, message) do
    put_flash(socket, :info, message)
  end
end
