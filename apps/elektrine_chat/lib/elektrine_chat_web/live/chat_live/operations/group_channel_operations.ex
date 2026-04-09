defmodule ElektrineChatWeb.ChatLive.Operations.GroupChannelOperations do
  @moduledoc """
  Handles group and channel creation, browsing, and joining.
  Extracted from ChatLive.Home.
  """

  import Phoenix.LiveView
  import Phoenix.Component
  import ElektrineWeb.Live.NotificationHelpers

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  alias Elektrine.Messaging, as: Messaging
  alias Elektrine.Uploads
  alias ElektrineChatWeb.ChatLive.Operations.Helpers

  def handle_event("toggle_new_chat", _params, socket) do
    show_new_chat = !socket.assigns.ui.show_new_chat

    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_new_chat, show_new_chat))
     |> assign(:search, %{socket.assigns.search | query: "", results: []})}
  end

  def handle_event("show_create_group", _params, socket) do
    updated_ui =
      socket.assigns.ui
      |> Map.put(:show_group_modal, true)
      |> Map.put(:show_new_chat, false)

    {:noreply,
     socket
     |> assign(:ui, updated_ui)
     |> assign(:form, %{socket.assigns.form | selected_users: []})
     |> assign(:search, %{socket.assigns.search | query: "", results: []})}
  end

  def handle_event("show_create_server", _params, socket) do
    updated_ui =
      socket.assigns.ui
      |> Map.put(:show_server_modal, true)
      |> Map.put(:show_group_modal, false)
      |> Map.put(:show_channel_modal, false)
      |> Map.put(:show_browse_modal, false)
      |> Map.put(:show_new_chat, false)

    {:noreply, assign(socket, :ui, updated_ui)}
  end

  def handle_event("hide_create_server", _params, socket) do
    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_server_modal, false))
     |> clear_upload_entries(:server_icon_upload)}
  end

  def handle_event("show_create_channel", _params, socket) do
    case selected_server_id(socket) do
      nil ->
        {:noreply,
         socket
         |> notify_error("Select a server first, then create channels inside it")}

      _server_id ->
        {:noreply,
         assign(
           socket,
           :ui,
           socket.assigns.ui
           |> Map.put(:show_channel_modal, true)
           |> Map.put(:show_new_chat, false)
         )}
    end
  end

  def handle_event("create_group", params, socket) do
    name = params["name"]
    selected_users = socket.assigns.form.selected_users

    if not Elektrine.Strings.present?(name) || Enum.empty?(selected_users) do
      {:noreply, notify_error(socket, "Please enter a name and select at least one user")}
    else
      case Messaging.create_chat_group_conversation(
             socket.assigns.current_user.id,
             %{name: name},
             selected_users
           ) do
        {:ok, conversation} ->
          {:noreply,
           socket
           |> assign(:ui, Map.put(socket.assigns.ui, :show_group_modal, false))
           |> push_patch(to: Elektrine.Paths.chat_path(conversation))
           |> notify_info("Chat created!")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to create chat")}
      end
    end
  end

  def handle_event("create_server", params, socket) do
    server_params = Map.get(params, "server", %{})
    name = Map.get(server_params, "name", "")
    description = Map.get(server_params, "description", "")
    is_public = parse_checkbox_value(Map.get(server_params, "is_public"))

    with true <- Elektrine.Strings.present?(name),
         {:ok, icon_url} <- consume_entity_image_upload(socket, :server_icon_upload) do
      attrs = %{
        name: String.trim(name),
        description: normalize_optional_text(description),
        icon_url: icon_url,
        is_public: is_public
      }

      case Messaging.create_server(socket.assigns.current_user.id, attrs) do
        {:ok, server} ->
          joined_servers = Messaging.list_servers(socket.assigns.current_user.id)
          server_channel = default_server_channel(server.channels)

          base_socket =
            socket
            |> assign(:joined_servers, joined_servers)
            |> assign(:active_server_id, server.id)
            |> assign(:ui, Map.put(socket.assigns.ui, :show_server_modal, false))
            |> notify_info("Server created!")

          case server_channel do
            nil ->
              {:noreply, push_patch(base_socket, to: Elektrine.Paths.chat_root_path())}

            channel ->
              {:noreply, push_patch(base_socket, to: Elektrine.Paths.chat_path(channel))}
          end

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, notify_error(socket, first_changeset_error(changeset))}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to create server")}
      end
    else
      false ->
        {:noreply, notify_error(socket, "Please enter a server name")}

      {:error, reason} ->
        {:noreply, notify_error(socket, reason)}
    end
  end

  def handle_event("create_channel", params, socket) do
    channel_params = Map.get(params, "channel", %{})
    name = params["name"] || channel_params["name"]
    description = params["description"] || channel_params["description"]
    topic = params["channel_topic"] || channel_params["channel_topic"]
    is_private = parse_checkbox_value(params["is_private"] || channel_params["is_private"])

    with server_id when is_integer(server_id) <- selected_server_id(socket),
         true <- Elektrine.Strings.present?(name) do
      attrs = %{
        name: String.trim(name),
        description: normalize_optional_text(description),
        channel_topic: normalize_optional_text(topic),
        is_public: !is_private
      }

      case Messaging.create_server_channel(server_id, socket.assigns.current_user.id, attrs) do
        {:ok, channel} ->
          {:noreply,
           socket
           |> assign(:ui, Map.put(socket.assigns.ui, :show_channel_modal, false))
           |> push_patch(to: Elektrine.Paths.chat_path(channel))
           |> notify_info("Channel created!")}

        {:error, :unauthorized} ->
          {:noreply,
           socket
           |> notify_error("You don't have permission to create channels in this server")}

        {:error, :not_found} ->
          {:noreply, notify_error(socket, "Server not found")}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to create channel")}
      end
    else
      nil ->
        {:noreply, notify_error(socket, "Select a server first, then create channels inside it")}

      false ->
        {:noreply, notify_error(socket, "Please enter a channel name")}
    end
  end

  def handle_event("cancel_create", _params, socket) do
    updated_ui =
      socket.assigns.ui
      |> Map.put(:show_group_modal, false)
      |> Map.put(:show_channel_modal, false)
      |> Map.put(:show_server_modal, false)
      |> Map.put(:show_new_chat, false)

    {:noreply,
     socket
     |> assign(:ui, updated_ui)
     |> clear_upload_entries(:server_icon_upload)
     |> clear_upload_entries(:group_avatar_upload)
     |> clear_upload_entries(:channel_avatar_upload)
     |> assign(:form, %{socket.assigns.form | selected_users: []})}
  end

  def handle_event("toggle_user_selection", %{"user_id" => user_id}, socket) do
    user_id = String.to_integer(user_id)
    selected = socket.assigns.form.selected_users

    updated =
      if user_id in selected do
        List.delete(selected, user_id)
      else
        [user_id | selected]
      end

    {:noreply, assign(socket, :form, %{socket.assigns.form | selected_users: updated})}
  end

  def handle_event("show_browse_modal", _params, socket) do
    public_servers = Messaging.list_public_servers(socket.assigns.current_user.id)
    public_groups = Messaging.list_chat_public_groups()

    updated_ui =
      socket.assigns.ui
      |> Map.put(:show_browse_modal, true)
      |> Map.put(:show_new_chat, false)

    {:noreply,
     socket
     |> assign(:ui, updated_ui)
     |> assign(:search, %{socket.assigns.search | browse_query: ""})
     |> assign(:browse, %{
       socket.assigns.browse
       | tab: "servers",
         public_servers: public_servers,
         public_channels: [],
         public_groups: public_groups,
         filtered_servers: public_servers,
         filtered_channels: [],
         filtered_groups: public_groups
     })}
  end

  def handle_event("hide_browse_modal", _params, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_browse_modal, false))}
  end

  def handle_event("browse_tab", %{"tab" => tab}, socket) do
    normalized_tab = if tab in ["servers", "groups"], do: tab, else: "servers"
    updated_browse = %{socket.assigns.browse | tab: normalized_tab}
    {:noreply, assign(socket, :browse, updated_browse)}
  end

  def handle_event("browse_search", %{"search" => query}, socket) do
    search_query = String.trim(query || "")
    normalized_query = String.downcase(search_query)

    filtered_servers =
      if normalized_query == "" do
        socket.assigns.browse.public_servers
      else
        Enum.filter(socket.assigns.browse.public_servers, fn server ->
          String.contains?(String.downcase(server.name || ""), normalized_query) ||
            String.contains?(String.downcase(server.description || ""), normalized_query) ||
            String.contains?(String.downcase(server.origin_domain || ""), normalized_query)
        end)
      end

    filtered_groups =
      if normalized_query == "" do
        socket.assigns.browse.public_groups
      else
        Enum.filter(socket.assigns.browse.public_groups, fn g ->
          String.contains?(String.downcase(g.name || ""), normalized_query) ||
            String.contains?(String.downcase(g.description || ""), normalized_query)
        end)
      end

    {:noreply,
     socket
     |> assign(:search, %{socket.assigns.search | browse_query: search_query})
     |> assign(:browse, %{
       socket.assigns.browse
       | filtered_servers: filtered_servers,
         filtered_channels: [],
         filtered_groups: filtered_groups
     })}
  end

  def handle_event("join_conversation", %{"conversation_id" => conversation_id}, socket) do
    {:noreply, push_patch(socket, to: Elektrine.Paths.chat_join_path(conversation_id))}
  end

  def handle_event("join_group", %{"group_id" => group_id}, socket) do
    conversation_id = String.to_integer(group_id)

    case Messaging.join_conversation(conversation_id, socket.assigns.current_user.id) do
      {:ok, :pending} ->
        {:noreply, notify_info(socket, "Join request sent")}

      {:ok, _} ->
        {:noreply,
         socket
         |> push_patch(to: Elektrine.Paths.chat_path(conversation_id))
         |> notify_info("Joined chat")}

      {:error, _} ->
        {:noreply, notify_error(socket, "Failed to join chat")}
    end
  end

  def handle_event("join_channel", %{"channel_id" => channel_id}, socket) do
    _ = channel_id

    {:noreply,
     notify_error(socket, "Channels are server-scoped. Join the server to access its channels.")}
  end

  def handle_event("filter_server", %{"server_id" => server_id}, socket) do
    case parse_server_id(server_id) do
      {:ok, parsed_server_id} ->
        {:noreply,
         socket
         |> apply_server_scope(parsed_server_id)
         |> push_patch(to: Elektrine.Paths.chat_root_path())}

      :error ->
        {:noreply, notify_error(socket, "Invalid server")}
    end
  end

  def handle_event("select_server", %{"server_id" => server_id}, socket) do
    case parse_server_id(server_id) do
      {:ok, parsed_server_id} ->
        socket = apply_server_scope(socket, parsed_server_id)

        case first_server_channel_identifier(socket.assigns.conversation.list, parsed_server_id) do
          nil ->
            {:noreply,
             socket
             |> assign(:conversation, %{socket.assigns.conversation | selected: nil})
             |> push_patch(to: Elektrine.Paths.chat_root_path())}

          conversation_identifier ->
            {:noreply, push_patch(socket, to: Elektrine.Paths.chat_path(conversation_identifier))}
        end

      :error ->
        {:noreply, notify_error(socket, "Invalid server")}
    end
  end

  def handle_event("clear_server_scope", _params, socket) do
    {:noreply,
     socket
     |> apply_server_scope(nil)
     |> push_patch(to: Elektrine.Paths.chat_root_path())}
  end

  def handle_event("join_server", %{"server_id" => server_id}, socket) do
    current_user_id = socket.assigns.current_user.id

    case parse_server_id(server_id) do
      {:ok, parsed_server_id} ->
        case Messaging.join_server(parsed_server_id, current_user_id) do
          {:ok, _member} ->
            navigate_to_joined_server(socket, parsed_server_id, "Joined server")

          {:error, :already_member} ->
            navigate_to_joined_server(socket, parsed_server_id, nil)

          {:error, :not_public} ->
            {:noreply, notify_error(socket, "This server is private")}

          {:error, :not_found} ->
            {:noreply, notify_error(socket, "Server not found")}

          {:error, _reason} ->
            {:noreply, notify_error(socket, "Failed to join server")}
        end

      :error ->
        {:noreply, notify_error(socket, "Invalid server")}
    end
  end

  defp navigate_to_joined_server(socket, server_id, success_message) do
    case Messaging.get_server(server_id, socket.assigns.current_user.id) do
      {:ok, server} ->
        server_channel = default_server_channel(server.channels)

        cond do
          server_channel ->
            {:noreply,
             socket
             |> apply_server_scope(server_id)
             |> assign(:ui, Map.put(socket.assigns.ui, :show_browse_modal, false))
             |> maybe_notify_info(success_message)
             |> push_patch(to: Elektrine.Paths.chat_path(server_channel))}

          success_message ->
            {:noreply,
             socket
             |> apply_server_scope(server_id)
             |> assign(:ui, Map.put(socket.assigns.ui, :show_browse_modal, false))
             |> notify_info(success_message)
             |> notify_warning("Joined server, but it has no channels yet")
             |> push_patch(to: Elektrine.Paths.chat_root_path())}

          true ->
            {:noreply,
             socket
             |> apply_server_scope(server_id)
             |> assign(:ui, Map.put(socket.assigns.ui, :show_browse_modal, false))
             |> notify_warning("This server has no channels yet")
             |> push_patch(to: Elektrine.Paths.chat_root_path())}
        end

      {:error, :not_found} ->
        {:noreply, notify_error(socket, "Server not found")}
    end
  end

  defp parse_server_id(server_id) when is_integer(server_id), do: {:ok, server_id}

  defp parse_server_id(server_id) when is_binary(server_id) do
    case Integer.parse(server_id) do
      {parsed_server_id, ""} -> {:ok, parsed_server_id}
      _ -> :error
    end
  end

  defp parse_server_id(_), do: :error

  defp first_server_channel_identifier(conversations, server_id)
       when is_list(conversations) and is_integer(server_id) do
    conversations
    |> Enum.filter(&(&1.type == "channel" and &1.server_id == server_id))
    |> Enum.sort_by(&{&1.channel_position || 0, &1.id})
    |> List.first()
    |> case do
      nil -> nil
      conversation -> conversation.hash || conversation.id
    end
  end

  defp first_server_channel_identifier(_conversations, _server_id), do: nil

  defp default_server_channel(channels) when is_list(channels) do
    channels
    |> Enum.filter(&(&1.type == "channel"))
    |> List.first()
  end

  defp default_server_channel(_), do: nil

  defp maybe_notify_info(socket, nil), do: socket
  defp maybe_notify_info(socket, message), do: notify_info(socket, message)

  defp apply_server_scope(socket, active_server_id) do
    scoped_conversations =
      Helpers.scope_conversations_to_server(socket.assigns.conversation.list, active_server_id)

    filtered_conversations =
      case String.trim(socket.assigns.search.conversation_query || "") do
        "" ->
          scoped_conversations

        query ->
          Helpers.filter_conversations(
            scoped_conversations,
            query,
            socket.assigns.current_user.id
          )
      end

    socket
    |> assign(:active_server_id, active_server_id)
    |> assign(:conversation, %{socket.assigns.conversation | filtered: filtered_conversations})
  end

  defp selected_server_id(socket) do
    case socket.assigns.conversation.selected do
      %{server_id: server_id} when is_integer(server_id) -> server_id
      _ -> socket.assigns[:active_server_id]
    end
  end

  defp normalize_optional_text(nil), do: nil

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_text(_), do: nil

  defp parse_checkbox_value(value) when is_list(value) do
    Enum.any?(value, &parse_checkbox_value/1)
  end

  defp parse_checkbox_value(value) do
    value in [true, "true", "on", "1", 1]
  end

  defp first_changeset_error(%Ecto.Changeset{} = changeset) do
    case changeset.errors do
      [{_field, {message, opts}} | _] ->
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)

      _ ->
        "Failed to create server"
    end
  end

  defp consume_entity_image_upload(socket, upload_name) do
    upload_results =
      consume_uploaded_entries(socket, upload_name, fn %{path: path}, entry ->
        upload = %Plug.Upload{
          path: path,
          content_type: entry.client_type,
          filename: entry.client_name
        }

        case Uploads.upload_avatar(upload, socket.assigns.current_user.id) do
          {:ok, metadata} ->
            {:ok, %{ok: true, url: Uploads.avatar_url(metadata.key)}}

          {:error, reason} ->
            {:ok, %{ok: false, reason: reason}}
        end
      end)

    case Enum.find(upload_results, &(!&1.ok)) do
      %{reason: reason} ->
        {:error, upload_error_message(reason)}

      nil ->
        uploaded_url =
          upload_results
          |> Enum.find_value(fn
            %{ok: true, url: url} when is_binary(url) and url != "" -> url
            _ -> nil
          end)

        {:ok, uploaded_url}
    end
  end

  defp clear_upload_entries(socket, upload_name) do
    refs =
      case socket.assigns[:uploads] && socket.assigns.uploads[upload_name] do
        %{entries: entries} when is_list(entries) -> Enum.map(entries, & &1.ref)
        _ -> []
      end

    Enum.reduce(refs, socket, fn ref, acc ->
      cancel_upload(acc, upload_name, ref)
    end)
  end

  defp upload_error_message({_, message}) when is_binary(message), do: message

  defp upload_error_message(reason) do
    "Image upload failed: #{inspect(reason)}"
  end
end
