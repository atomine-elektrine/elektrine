defmodule ElektrineWeb.EmailLive.Operations.AliasOperations do
  @moduledoc """
  Handles email alias operations for email inbox.
  """

  require Logger

  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  alias Elektrine.Email

  def handle_event("create_alias", %{"alias" => alias_params}, socket) do
    user = socket.assigns.current_user

    # Extract username and domain
    username = alias_params["username"]
    # Default to elektrine.com if not specified
    domain = alias_params["domain"] || "elektrine.com"

    if username && String.trim(username) != "" do
      # Use single-domain creation
      alias_creation_params = %{
        username: String.trim(username),
        domain: domain,
        user_id: user.id,
        target_email: alias_params["target_email"] || "",
        description: alias_params["description"] || "",
        enabled: alias_params["enabled"] == "true"
      }

      case Email.create_alias(alias_creation_params) do
        {:ok, _alias} ->
          aliases = Email.list_aliases(user.id)
          alias_changeset = Email.change_alias(%Email.Alias{})

          {:noreply,
           socket
           |> assign(:aliases, aliases)
           |> assign(:alias_form, to_form(alias_changeset))
           |> notify_info("Email alias created: #{username}@#{domain}")}

        {:error, changeset} ->
          # Log detailed error for debugging
          Logger.error("Failed to create alias for user #{user.id}: #{inspect(changeset.errors)}")
          Logger.error("Alias creation failed for #{username}@#{domain}")

          # Handle single-domain creation error
          error_msgs =
            Enum.map(changeset.errors, fn {field, {msg, _}} ->
              case field do
                # Use just the message for alias_email errors
                :alias_email -> msg
                _ -> "#{field}: #{msg}"
              end
            end)
            |> Enum.uniq()
            |> Enum.join(", ")

          error_message =
            if error_msgs != "" do
              # Ensure error message is plain text, not HTML
              Phoenix.HTML.html_escape(error_msgs) |> Phoenix.HTML.safe_to_string()
            else
              "Failed to create alias"
            end

          {:noreply,
           socket
           |> assign(:alias_form, to_form(changeset))
           |> notify_error(error_message)}
      end
    else
      {:noreply, notify_error(socket, "Username is required")}
    end
  end

  def handle_event("toggle_alias", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Email.get_alias(id, user.id) do
      nil ->
        {:noreply, notify_error(socket, "Alias not found")}

      alias ->
        case Email.update_alias(alias, %{enabled: !alias.enabled}) do
          {:ok, _alias} ->
            aliases = Email.list_aliases(user.id)
            status = if alias.enabled, do: "disabled", else: "enabled"

            {:noreply,
             socket
             |> assign(:aliases, aliases)
             |> notify_info("Alias #{status} successfully")}

          {:error, changeset} ->
            Logger.error(
              "Failed to toggle alias #{id} for user #{user.id}: #{inspect(changeset.errors)}"
            )

            error_msg =
              case changeset.errors do
                [] ->
                  "Failed to update alias status"

                errors ->
                  errors
                  |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field}: #{msg}" end)
              end

            {:noreply, notify_error(socket, error_msg)}
        end
    end
  end

  def handle_event("delete_alias", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Email.get_alias(id, user.id) do
      nil ->
        {:noreply, notify_error(socket, "Alias not found")}

      alias ->
        case Email.delete_alias(alias) do
          {:ok, _alias} ->
            aliases = Email.list_aliases(user.id)

            {:noreply,
             socket
             |> assign(:aliases, aliases)
             |> notify_info("Alias deleted successfully")}

          {:error, _changeset} ->
            {:noreply, notify_error(socket, "Failed to delete alias")}
        end
    end
  end

  def handle_event("edit_alias", %{"id" => id}, socket) do
    alias_to_edit = Enum.find(socket.assigns.aliases, &(&1.id == String.to_integer(id)))

    if alias_to_edit do
      changeset = Email.change_alias(alias_to_edit)

      {:noreply,
       socket
       |> assign(:editing_alias, alias_to_edit)
       |> assign(:edit_alias_form, to_form(changeset))}
    else
      {:noreply, notify_error(socket, "Alias not found")}
    end
  end

  def handle_event("cancel_edit_alias", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_alias, nil)
     |> assign(:edit_alias_form, nil)}
  end

  def handle_event("update_alias", params, socket) do
    alias_params = params["alias"] || %{}
    # Handle checkbox unchecked state - if enabled is not in params, it means unchecked
    alias_params = Map.put_new(alias_params, "enabled", "false")

    alias_to_update = socket.assigns.editing_alias

    case Email.update_alias(alias_to_update, alias_params) do
      {:ok, _updated_alias} ->
        # Reload aliases list
        aliases = Email.list_aliases(socket.assigns.current_user.id)

        {:noreply,
         socket
         |> assign(:aliases, aliases)
         |> assign(:editing_alias, nil)
         |> assign(:edit_alias_form, nil)
         |> notify_info("Alias updated successfully")}

      {:error, changeset} ->
        # Extract specific error messages from the changeset
        error_messages =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)
          |> Enum.map(fn {field, errors} ->
            "#{field}: #{Enum.join(errors, ", ")}"
          end)
          |> Enum.map_join("; ", & &1)

        error_msg =
          if error_messages != "" do
            "Failed to update alias: #{error_messages}"
          else
            "Failed to update alias: Invalid data provided"
          end

        # Log the error for debugging
        Logger.error(
          "Alias update failed for user #{socket.assigns.current_user.id}: #{inspect(changeset.errors)}"
        )

        Logger.error("Alias update failed for alias #{alias_to_update.id}")

        {:noreply,
         socket
         |> assign(:edit_alias_form, to_form(changeset))
         |> notify_error(error_msg)}
    end
  end

  def handle_event("update_mailbox_forwarding", %{"mailbox" => mailbox_params}, socket) do
    user = socket.assigns.current_user
    mailbox = Email.get_user_mailbox(user.id)

    # Handle checkbox unchecked state - if forward_enabled is not in params, it means unchecked
    mailbox_params = Map.put_new(mailbox_params, "forward_enabled", "false")

    case Email.update_mailbox_forwarding(mailbox, mailbox_params) do
      {:ok, updated_mailbox} ->
        mailbox_changeset = Email.change_mailbox_forwarding(updated_mailbox)

        {:noreply,
         socket
         |> assign(:mailbox, updated_mailbox)
         |> assign(:mailbox_form, to_form(mailbox_changeset))
         |> notify_info("Mailbox forwarding updated successfully")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:mailbox_form, to_form(changeset))
         |> notify_error("Failed to update mailbox forwarding")}
    end
  end
end
