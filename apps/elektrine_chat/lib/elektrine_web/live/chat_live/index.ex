defmodule ElektrineWeb.ChatLive.Index do
  use ElektrineChatWeb, :live_view
  require Logger

  alias Elektrine.Accounts.User
  alias Elektrine.Calls
  alias Elektrine.Calls.Transport, as: CallTransport
  alias Elektrine.Constants
  alias Elektrine.Messaging, as: Messaging
  alias Elektrine.Messaging.ChatMessage
  alias Elektrine.Messaging.Federation.VoiceCalls
  alias Elektrine.Messaging.Message
  alias Elektrine.Uploads
  import ElektrineWeb.Components.User.Avatar
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.Components.Social.ContentJourney
  import ElektrineWeb.Components.Chat.Call
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.Social.EmbeddedPost
  import ElektrineWeb.Live.NotificationHelpers
  import ElektrineWeb.HtmlHelpers, only: [ensure_https: 1, render_custom_emojis: 1]

  # Import operation modules
  alias ElektrineWeb.ChatLive.Bootstrap
  alias ElektrineWeb.ChatLive.HandleFormatter
  alias ElektrineWeb.ChatLive.Operations.{CallInfoOperations, Helpers, MessageInfoOperations}

  @room_presence_heartbeat_ms 30_000

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    # Set locale from session or user preference
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    if connected?(socket) do
      # Subscribe to user's personal channel for notifications
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}")
      # Subscribe to global conversation events
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "conversations:all")
    end

    # Admins get higher upload limits
    chat_attachment_limit =
      if user.is_admin,
        do: Constants.max_chat_attachment_size_admin(),
        else: Constants.max_chat_attachment_size()

    # Load cached conversations to prevent flicker on refresh
    # This returns cached data instantly if available, only hits DB on cache miss
    cached_conversations = get_cached_conversations(user.id)
    cached_unread = get_cached_unread_count(user.id)
    cached_servers = Messaging.list_servers(user.id)

    custom_emojis = load_custom_emojis()
    federation_preview = build_federation_preview()

    loading_conversations =
      !Enum.empty?(cached_conversations) || Messaging.user_has_conversations?(user.id)

    # Initialize with cached data to prevent flicker
    socket =
      Bootstrap.initialize_socket(socket,
        cached_conversations: cached_conversations,
        cached_unread: cached_unread,
        cached_servers: cached_servers,
        chat_attachment_limit: chat_attachment_limit,
        user_token: Helpers.generate_user_token(user.id),
        custom_emojis: custom_emojis,
        federation_preview: federation_preview,
        loading_conversations: loading_conversations
      )
      |> restore_active_call_state(user.id)

    # Load conversations async after connection
    if connected?(socket) do
      send(self(), :load_conversations)

      if socket.assigns.call.active_call do
        send(self(), :resume_active_call)
      end
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(
        %{"conversation_id" => conversation_identifier},
        _url,
        %{assigns: %{live_action: :join}} = socket
      ) do
    # Handle join link - first try to find by hash, then by ID
    conversation_id =
      case Messaging.get_conversation_by_hash(conversation_identifier) do
        %{id: id} ->
          id

        nil ->
          # Fallback to ID lookup for backwards compatibility
          case Integer.parse(conversation_identifier) do
            {id, ""} -> id
            _ -> nil
          end
      end

    if conversation_id do
      case Messaging.join_conversation(conversation_id, socket.assigns.current_user.id) do
        {:ok, :pending} ->
          {:noreply,
           socket
           |> notify_info("Join request sent")
           |> push_navigate(to: ~p"/chat")}

        {:ok, _} ->
          # Successfully joined, trigger conversation refresh and redirect
          {:noreply,
           socket
           |> maybe_schedule_conversation_refresh(100)
           |> notify_info("Successfully joined!")
           |> push_navigate(to: ~p"/chat/#{conversation_identifier}")}

        {:error, :already_member} ->
          # Already a member, just go to the conversation using the original identifier
          {:noreply,
           socket
           |> push_navigate(to: ~p"/chat/#{conversation_identifier}")}

        {:error, :not_public_channel} ->
          {:noreply,
           socket
           |> notify_error("This is a private group or channel - you need an invitation to join")
           |> push_navigate(to: ~p"/chat")}

        {:error, _} ->
          {:noreply,
           socket
           |> notify_error("Unable to join this conversation")
           |> push_navigate(to: ~p"/chat")}
      end
    else
      # Invalid conversation identifier
      {:noreply,
       socket
       |> notify_error("Invalid chat invite link")
       |> push_navigate(to: ~p"/chat")}
    end
  end

  def handle_params(%{"conversation_id" => conversation_identifier}, _url, socket) do
    user_id = socket.assigns.current_user.id

    case Messaging.get_conversation_for_chat_by_hash!(conversation_identifier, user_id) do
      {:ok, conversation} ->
        {:noreply, open_conversation(socket, conversation)}

      {:error, :not_found} ->
        case Integer.parse(conversation_identifier) do
          {conversation_id, ""} ->
            case Messaging.get_conversation_for_chat!(conversation_id, user_id) do
              {:ok, conversation} ->
                # If accessed by ID instead of hash, redirect to canonical hash URL.
                if conversation_identifier != conversation.hash && conversation.hash do
                  {:noreply, push_navigate(socket, to: ~p"/chat/#{conversation.hash}")}
                else
                  {:noreply, open_conversation(socket, conversation)}
                end

              {:error, :not_found} ->
                {:noreply,
                 socket
                 |> notify_error("Chat not found")
                 |> push_navigate(to: ~p"/chat")}
            end

          _ ->
            {:noreply,
             socket
             |> notify_error("Invalid chat")
             |> push_navigate(to: ~p"/chat")}
        end
    end
  end

  def handle_params(params, _url, socket) do
    show_new_chat = params["composer"] == "message"

    # Clear selected conversation when navigating to /chat without a conversation_id
    {:noreply,
     socket
     |> cancel_room_presence_timer()
     |> assign(:conversation, %{socket.assigns.conversation | selected: nil})
     |> assign(:initial_messages_loading, false)
     |> assign(:ui, %{socket.assigns.ui | show_new_chat: show_new_chat})
     |> assign(:federation_presence, %{})}
  end

  @impl true
  def handle_event(event_name, params, socket) do
    # Delegate ALL events to the router
    ElektrineWeb.ChatLive.Router.route_event(event_name, params, socket)
  end

  # All event handlers now in operation modules via Router

  # Handle messages from components
  # Load conversations asynchronously after mount
  def handle_info(:load_conversations, socket) do
    user = socket.assigns.current_user

    # Get all conversations but filter out Timeline and Community channels from chat view
    all_conversations = Messaging.list_conversations(user.id)

    conversations_filtered =
      Enum.reject(all_conversations, &(&1.type in ["timeline", "community"]))

    unread_count = Messaging.get_unread_count(user.id)

    # Calculate unread counts and sort conversations
    unread_counts = Helpers.calculate_unread_counts(conversations_filtered, user.id)

    conversations =
      Helpers.sort_conversations_by_unread(conversations_filtered, unread_counts, user.id)

    # Calculate read status for last messages
    last_message_read_status = Helpers.calculate_last_message_read_status(conversations, user.id)
    joined_servers = Messaging.list_servers(user.id)

    {:noreply,
     socket
     |> assign(:conversation, %{
       socket.assigns.conversation
       | list: conversations,
         filtered:
           refresh_conversation_filter(
             conversations,
             socket.assigns.search.conversation_query,
             user.id,
             socket.assigns[:active_server_id]
           ),
         last_message_read_status: last_message_read_status,
         unread_count: unread_count,
         unread_counts: unread_counts
     })
     |> assign(:joined_servers, joined_servers)
     |> assign(:loading_conversations, false)}
  end

  def handle_info({:update_group_form, group_params}, socket) do
    updated_form = %{
      socket.assigns.form
      | group_name: Map.get(group_params, "name", socket.assigns.form.group_name),
        group_description:
          Map.get(group_params, "description", socket.assigns.form.group_description),
        group_is_public:
          Map.get(group_params, "is_public", socket.assigns.form.group_is_public) == "true"
    }

    {:noreply, assign(socket, :form, updated_form)}
  end

  # Handle messages from components
  def handle_info({:search_users, query}, socket) do
    if String.length(query) >= 2 do
      results =
        query
        |> Messaging.search_users(socket.assigns.current_user.id)
        |> maybe_add_remote_dm_search_result(query)

      {:noreply, assign(socket, :search_results, results)}
    else
      {:noreply, assign(socket, :search_results, [])}
    end
  end

  def handle_info({:show_direct_search}, socket) do
    updated_ui =
      socket.assigns.ui
      |> Map.put(:show_create_group, false)
      |> Map.put(:show_create_channel, false)
      |> Map.put(:show_browse_channels, false)

    {:noreply,
     socket
     |> assign(:ui, updated_ui)}
  end

  def handle_info({:start_dm, %{"remote_handle" => remote_handle}}, socket)
      when is_binary(remote_handle) and remote_handle != "" do
    current_user_id = socket.assigns.current_user.id

    case Messaging.create_remote_dm_conversation(current_user_id, remote_handle) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign(:ui, Map.put(socket.assigns.ui, :show_new_chat, false))
         |> assign(:search, %{socket.assigns.search | query: "", results: []})
         |> push_navigate(to: ~p"/chat/#{conversation.hash || conversation.id}")}

      {:error, :invalid_remote_handle} ->
        {:noreply, notify_error(socket, "Use handle format user@domain")}

      {:error, :unknown_peer} ->
        {:noreply,
         notify_error(
           socket,
           "That domain could not be reached through federation discovery"
         )}

      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> notify_error(
           "You are creating too many conversations. Please wait a moment and try again."
         )
         |> assign(:ui, Map.put(socket.assigns.ui, :show_profile_modal, false))}

      {:error, reason} ->
        error_message = Elektrine.Privacy.privacy_error_message(reason)

        {:noreply,
         socket
         |> notify_error(error_message)
         |> assign(:ui, Map.put(socket.assigns.ui, :show_profile_modal, false))}
    end
  end

  def handle_info({:start_dm, %{"user_id" => user_id_str}}, socket) do
    handle_info({:start_dm, user_id_str}, socket)
  end

  def handle_info({:start_dm, user_id_str}, socket) when is_binary(user_id_str) do
    user_id = String.to_integer(user_id_str)
    current_user_id = socket.assigns.current_user.id

    case Messaging.create_dm_conversation(current_user_id, user_id) do
      {:ok, conversation} ->
        {:noreply,
         socket
         |> assign(:ui, Map.put(socket.assigns.ui, :show_new_chat, false))
         |> assign(:search, %{socket.assigns.search | query: "", results: []})
         |> push_navigate(to: ~p"/chat/#{conversation.hash || conversation.id}")}

      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> notify_error(
           "You are creating too many conversations. Please wait a moment and try again."
         )
         |> assign(:ui, Map.put(socket.assigns.ui, :show_profile_modal, false))}

      {:error, reason} ->
        error_message = Elektrine.Privacy.privacy_error_message(reason)

        {:noreply,
         socket
         |> notify_error(error_message)
         |> assign(:ui, Map.put(socket.assigns.ui, :show_profile_modal, false))}
    end
  end

  def handle_info({:show_create_group}, socket) do
    updated_ui =
      socket.assigns.ui
      |> Map.put(:show_group_modal, true)
      |> Map.put(:show_channel_modal, false)
      |> Map.put(:show_new_chat, false)

    {:noreply,
     socket
     |> assign(:ui, updated_ui)}
  end

  def handle_info({:show_create_channel}, socket) do
    case selected_server_id(socket) do
      nil ->
        {:noreply,
         socket
         |> notify_error("Select a server first, then create channels inside it")}

      _server_id ->
        updated_ui =
          socket.assigns.ui
          |> Map.put(:show_channel_modal, true)
          |> Map.put(:show_group_modal, false)
          |> Map.put(:show_new_chat, false)

        {:noreply,
         socket
         |> assign(:ui, updated_ui)}
    end
  end

  def handle_info({:show_browse_modal}, socket) do
    public_servers = Messaging.list_public_servers(socket.assigns.current_user.id)
    public_groups = Messaging.list_public_groups()

    updated_ui =
      socket.assigns.ui
      |> Map.put(:show_browse_modal, true)
      |> Map.put(:show_group_modal, false)
      |> Map.put(:show_channel_modal, false)
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

  def handle_info({:close_group_modal}, socket) do
    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_group_modal, false))
     |> clear_upload_entries(:group_avatar_upload)}
  end

  def handle_info({:close_channel_modal}, socket) do
    {:noreply,
     socket
     |> assign(:ui, Map.put(socket.assigns.ui, :show_channel_modal, false))
     |> clear_upload_entries(:channel_avatar_upload)}
  end

  def handle_info({:create_group, group_params, selected_users}, socket) do
    name = Map.get(group_params, "name", "")
    description = Map.get(group_params, "description", "")
    is_public = Map.get(group_params, "is_public") == "true"

    if String.trim(name) != "" and selected_users != [] do
      member_ids = Enum.map(selected_users, & &1.id)

      case consume_entity_image_upload(socket, :group_avatar_upload) do
        {:ok, avatar_url} ->
          case Messaging.create_group_conversation(
                 socket.assigns.current_user.id,
                 %{
                   name: String.trim(name),
                   description: String.trim(description),
                   avatar_url: avatar_url,
                   is_public: is_public
                 },
                 member_ids
               ) do
            {:ok, conversation} ->
              {:noreply,
               socket
               |> assign(:ui, Map.put(socket.assigns.ui, :show_group_modal, false))
               |> assign(:form, %{socket.assigns.form | selected_users: []})
               |> assign(:search, %{socket.assigns.search | query: "", results: []})
               |> notify_info("Group created successfully!")
               |> push_navigate(to: ~p"/chat/#{conversation.hash || conversation.id}")}

            {:ok, conversation, failed_count} ->
              {:noreply,
               socket
               |> assign(:ui, Map.put(socket.assigns.ui, :show_group_modal, false))
               |> assign(:form, %{socket.assigns.form | selected_users: []})
               |> assign(:search, %{socket.assigns.search | query: "", results: []})
               |> notify_warning(
                 "Group created but #{failed_count} user(s) could not be added due to their privacy settings"
               )
               |> push_navigate(to: ~p"/chat/#{conversation.hash || conversation.id}")}

            {:error, :group_limit_exceeded} ->
              {:noreply,
               socket
               |> notify_error("You've reached the maximum limit of 20 groups")}

            {:error, _changeset} ->
              {:noreply,
               socket
               |> notify_error("Failed to create group. Please try again.")}
          end

        {:error, reason} ->
          {:noreply, notify_error(socket, reason)}
      end
    else
      {:noreply,
       socket
       |> notify_error("Please provide a group name and select at least one member.")}
    end
  end

  def handle_info({:create_channel, channel_params}, socket) do
    name = Map.get(channel_params, "name", "")
    description = Map.get(channel_params, "description", "")
    topic = Map.get(channel_params, "channel_topic", "")
    is_private = parse_checkbox_value(Map.get(channel_params, "is_private"))

    with server_id when is_integer(server_id) <- selected_server_id(socket),
         true <- String.trim(name) != "",
         {:ok, avatar_url} <- consume_entity_image_upload(socket, :channel_avatar_upload) do
      attrs = %{
        name: String.trim(name),
        description: normalize_optional_text(description),
        channel_topic: normalize_optional_text(topic),
        avatar_url: avatar_url,
        is_public: !is_private
      }

      case Messaging.create_server_channel(server_id, socket.assigns.current_user.id, attrs) do
        {:ok, channel} ->
          {:noreply,
           socket
           |> assign(:ui, Map.put(socket.assigns.ui, :show_channel_modal, false))
           |> notify_info("Channel created successfully!")
           |> push_navigate(to: ~p"/chat/#{channel.hash || channel.id}")}

        {:error, :unauthorized} ->
          {:noreply,
           socket
           |> notify_error("You don't have permission to create channels in this server")}

        {:error, :not_found} ->
          {:noreply,
           socket
           |> notify_error("Server not found")}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> notify_error("Failed to create channel. Please try again.")}
      end
    else
      nil ->
        {:noreply,
         socket
         |> notify_error("Select a server first, then create channels inside it")}

      false ->
        {:noreply,
         socket
         |> notify_error("Please provide a channel name.")}

      {:error, reason} ->
        {:noreply, notify_error(socket, reason)}
    end
  end

  def handle_info({:search_users_for_group, query}, socket) do
    search_results =
      if String.length(query) >= 2 do
        Elektrine.Accounts.search_users(query, socket.assigns.current_user.id)
      else
        []
      end

    {:noreply,
     socket
     |> assign(:search, %{socket.assigns.search | query: query, results: search_results})}
  end

  def handle_info({:toggle_user_selection, user_id_str}, socket) do
    user_id = String.to_integer(user_id_str)
    selected_users = socket.assigns.form.selected_users

    updated_users =
      case Enum.find_index(selected_users, &(&1.id == user_id)) do
        nil ->
          # Add user to selection
          case Enum.find(socket.assigns.search.results, &(&1.id == user_id)) do
            %User{} = user -> [user | selected_users]
            nil -> selected_users
          end

        index ->
          # Remove user from selection
          List.delete_at(selected_users, index)
      end

    {:noreply, assign(socket, :form, %{socket.assigns.form | selected_users: updated_users})}
  end

  def handle_info({:send_message, message_content}, socket) do
    trimmed_content = String.trim(message_content)

    if trimmed_content != "" do
      case socket.assigns.conversation.selected do
        nil ->
          {:noreply, socket}

        conversation ->
          reply_to_id =
            if socket.assigns.message.reply_to, do: socket.assigns.message.reply_to.id, else: nil

          case Messaging.create_text_message(
                 conversation.id,
                 socket.assigns.current_user.id,
                 trimmed_content,
                 reply_to_id
               ) do
            {:ok, _message} ->
              {:noreply,
               socket
               |> assign(:message, %{socket.assigns.message | new_message: "", reply_to: nil})
               |> push_event("clear_message_input", %{})}

            {:error, _} ->
              {:noreply,
               socket
               |> notify_error("Failed to send message")}
          end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:react_to_message, message_id_str, emoji}, socket) do
    message_id = String.to_integer(message_id_str)

    case Messaging.add_chat_reaction(message_id, socket.assigns.current_user.id, emoji) do
      {:ok, _reaction} -> {:noreply, socket}
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_info({:load_conversation_messages, conversation_id}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == conversation_id do
      user_id = socket.assigns.current_user.id

      data = Messaging.get_conversation_messages(conversation_id, user_id, limit: 50)
      messages = Enum.reverse(data.messages)

      first_unread_message_id =
        Helpers.find_first_unread_message(messages, conversation_id, user_id)

      # Mark conversation as read after UI settles.
      Process.send_after(self(), {:mark_conversation_read, conversation_id}, 200)

      message_ids = Enum.map(messages, & &1.id)

      if message_ids != [] do
        # Load read receipts asynchronously to keep initial message paint snappy.
        Process.send_after(self(), {:load_read_status, message_ids, conversation_id}, 150)
      end

      user_ids =
        socket.assigns.conversation.selected.members
        |> Enum.map(& &1.user_id)
        |> Enum.uniq()

      timeout_status = Helpers.load_timeout_status(user_ids, conversation_id)

      updated_socket =
        socket
        |> assign(:messages, messages)
        |> assign(:moderation, %{
          socket.assigns.moderation
          | user_timeout_status: timeout_status
        })
        |> assign(:first_unread_message_id, first_unread_message_id)
        |> assign(:has_more_older_messages, data.has_more_older)
        |> assign(:has_more_newer_messages, data.has_more_newer)
        |> assign(:oldest_message_id, data.oldest_id)
        |> assign(:newest_message_id, data.newest_id)
        |> assign(:loading_older_messages, false)
        |> assign(:loading_newer_messages, false)
        |> assign(:initial_messages_loading, false)

      Process.send_after(self(), :trigger_initial_scroll, 100)

      {:noreply, updated_socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:trigger_initial_scroll, socket) do
    # Determine the appropriate scroll action based on unread status
    if socket.assigns[:first_unread_message_id] do
      # There are unread messages, scroll to the unread indicator
      {:noreply,
       push_event(socket, "scroll_to_element", %{
         element_id: "unread-indicator",
         position: "top-third"
       })}
    else
      # No unread messages, scroll to bottom
      {:noreply, push_event(socket, "scroll_to_bottom", %{})}
    end
  end

  def handle_info({:scroll_to_unread, _message_id}, socket) do
    # Send event to scroll to the unread indicator
    {:noreply,
     push_event(socket, "scroll_to_element", %{
       element_id: "unread-indicator",
       position: "top-third"
     })}
  end

  # Scroll handler for media messages - ensures images have time to load
  def handle_info({:ensure_scroll_after_media, _message_id}, socket) do
    # Trigger scroll to bottom - the client-side handler includes retries for image loading
    {:noreply, push_event(socket, "scroll_to_bottom", %{})}
  end

  # Async load read status for faster initial render
  def handle_info({:load_read_status, message_ids, conversation_id}, socket) do
    # Only load if still viewing the same conversation
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == conversation_id do
      read_status = Messaging.get_read_status_for_messages(message_ids, conversation_id)

      {:noreply, assign(socket, :message, %{socket.assigns.message | read_status: read_status})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:mark_conversation_read, conversation_id}, socket) do
    # Mark conversation as read after user has had time to see it
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == conversation_id do
      user_id = socket.assigns.current_user.id

      # Update last read message ID to the last message in the conversation
      if socket.assigns[:messages] && socket.assigns.messages != [] do
        last_message = List.last(socket.assigns.messages)
        Messaging.update_last_read_message(conversation_id, user_id, last_message.id)
      else
        Messaging.mark_as_read(conversation_id, user_id)
      end

      # Mark any related notifications as read
      # Chat notifications use source_type "message", so clear all message notifications in this conversation
      if socket.assigns[:messages] && socket.assigns.messages != [] do
        message_ids = Enum.map(socket.assigns.messages, & &1.id)
        # This broadcasts :notification_updated and notification_count_updated automatically
        Elektrine.Notifications.mark_as_read_by_sources(user_id, "message", message_ids)
      end

      # Update unread counts and clear unread indicator
      updated_unread_counts =
        Map.put(socket.assigns.conversation.unread_counts, conversation_id, 0)

      # Broadcast that we read messages (for read receipts)
      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "conversation:#{conversation_id}",
        {:user_read_messages, user_id}
      )

      # Also broadcast to all conversation members so their conversation list updates
      members = Messaging.get_conversation_members(conversation_id)

      Enum.each(members, fn member ->
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "user:#{member.user_id}",
          {:user_read_messages_in_conversation,
           %{conversation_id: conversation_id, reader_id: user_id}}
        )
      end)

      {:noreply,
       socket
       |> assign(:conversation, %{
         socket.assigns.conversation
         | unread_counts: updated_unread_counts
       })
       |> assign(:first_unread_message_id, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:reply_to_message, message_id_str}, socket) do
    message_id = String.to_integer(message_id_str)
    reply_to_message = Enum.find(socket.assigns.messages, &(&1.id == message_id))

    {:noreply, assign(socket, :message, %{socket.assigns.message | reply_to: reply_to_message})}
  end

  def handle_info({:user_read_messages, user_id}, socket) do
    # User (possibly current user or another) read messages, update read status immediately

    # Update conversation list read status
    conversations = socket.assigns.conversation.list

    last_message_read_status =
      Helpers.calculate_last_message_read_status(conversations, socket.assigns.current_user.id)

    socket = assign(socket, :last_message_read_status, last_message_read_status)

    # Also update message read status if viewing a conversation
    socket =
      if socket.assigns.conversation.selected do
        conversation_id = socket.assigns.conversation.selected.id
        message_ids = Enum.map(socket.assigns.messages, & &1.id)

        # Fetch fresh read status
        read_status =
          if message_ids != [] do
            Messaging.get_read_status_for_messages(message_ids, conversation_id)
          else
            %{}
          end

        # If the current user read messages, also clear the unread divider
        socket =
          socket
          |> assign(:message_read_status, read_status)

        if user_id == socket.assigns.current_user.id do
          assign(socket, :first_unread_message_id, nil)
        else
          socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(
        {:user_read_messages_in_conversation,
         %{conversation_id: _conversation_id, reader_id: _reader_id}},
        socket
      ) do
    # Someone read messages in a conversation - update conversation list read status
    conversations = socket.assigns.conversation.list

    last_message_read_status =
      Helpers.calculate_last_message_read_status(conversations, socket.assigns.current_user.id)

    {:noreply, assign(socket, :last_message_read_status, last_message_read_status)}
  end

  def handle_info({:cancel_reply}, socket) do
    {:noreply, assign(socket, :message, %{socket.assigns.message | reply_to: nil})}
  end

  def handle_info({:timeout_added, timeout}, socket) do
    # Update timeout status in assigns
    updated_status = Map.put(socket.assigns.moderation.user_timeout_status, timeout.user_id, true)
    {:noreply, assign(socket, :user_timeout_status, updated_status)}
  end

  def handle_info({:timeout_removed, timeout}, socket) do
    # Update timeout status in assigns
    updated_status =
      Map.put(socket.assigns.moderation.user_timeout_status, timeout.user_id, false)

    {:noreply, assign(socket, :user_timeout_status, updated_status)}
  end

  def handle_info({:user_kicked, %{user_id: user_id, conversation_id: conversation_id}}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == conversation_id do
      # Refresh the conversation to remove the kicked member from the member list
      updated_conversation =
        socket.assigns.conversation.selected
        |> Map.update!(:members, fn members ->
          Enum.reject(members, fn member ->
            member.user_id == user_id && is_nil(member.left_at)
          end)
        end)

      # Update timeout status map to remove kicked user
      updated_timeout_status = Map.delete(socket.assigns.moderation.user_timeout_status, user_id)

      {:noreply,
       socket
       |> assign(:selected_conversation, updated_conversation)
       |> assign(:user_timeout_status, updated_timeout_status)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:member_joined, %{user_id: user_id, conversation_id: conversation_id}}, socket) do
    # Refresh conversation list when someone joins
    socket = maybe_schedule_conversation_refresh(socket, 50)

    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == conversation_id do
      # Refresh the conversation to show the new member
      case Messaging.get_conversation!(conversation_id, socket.assigns.current_user.id) do
        {:ok, updated_conversation} ->
          # Update timeout status for the new member
          timeout_status =
            Map.put(
              socket.assigns.moderation.user_timeout_status,
              user_id,
              Messaging.user_timed_out?(user_id, conversation_id)
            )

          {:noreply,
           socket
           |> assign(:selected_conversation, updated_conversation)
           |> assign(:user_timeout_status, timeout_status)}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:added_to_conversation, %{conversation_id: _conversation_id}}, socket) do
    {:noreply, maybe_schedule_conversation_refresh(socket, 50)}
  end

  def handle_info({:conversation_activity, %{conversation_id: _conversation_id}}, socket) do
    {:noreply, maybe_schedule_conversation_refresh(socket, 50)}
  end

  def handle_info({:member_left, %{user_id: _user_id, conversation_id: conversation_id}}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == conversation_id do
      # Refresh the conversation to show updated member list
      case Messaging.get_conversation!(conversation_id, socket.assigns.current_user.id) do
        {:ok, updated_conversation} ->
          {:noreply, assign(socket, :selected_conversation, updated_conversation)}

        {:error, _} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:kicked_from_conversation, %{conversation_id: conversation_id}}, socket) do
    # If the current user was kicked, redirect them away from the conversation
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == conversation_id do
      {:noreply,
       socket
       |> notify_error("You have been removed from this conversation")
       |> push_navigate(to: ~p"/chat")}
    else
      # Refresh conversations list to remove the conversation they were kicked from
      all_conversations = Messaging.list_conversations(socket.assigns.current_user.id)
      conversations = Enum.reject(all_conversations, &(&1.type in ["timeline", "community"]))
      {:noreply, assign(socket, :conversations, conversations)}
    end
  end

  def handle_info({:conversation_deleted, conversation_id}, socket) do
    # If viewing the deleted conversation, redirect to main chat
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == conversation_id do
      {:noreply,
       socket
       |> notify_info("This conversation has been disbanded")
       |> push_navigate(to: ~p"/chat")}
    else
      # Remove from conversations list
      conversations = Enum.reject(socket.assigns.conversation.list, &(&1.id == conversation_id))
      {:noreply, assign(socket, :conversations, conversations)}
    end
  end

  def handle_info({:report_submitted, _reportable_type, _reportable_id}, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, false)
     |> assign(:report_type, nil)
     |> assign(:report_id, nil)
     |> assign(:report_metadata, %{})
     |> notify_info("Report submitted successfully. Our team will review it shortly.")}
  end

  def handle_info(:refresh_conversations, socket) do
    # Refresh conversation list after a small delay for database consistency
    all_conversations = Messaging.list_conversations(socket.assigns.current_user.id)
    # Filter out Timeline and Community channels from chat view
    conversations_filtered =
      Enum.reject(all_conversations, &(&1.type in ["timeline", "community"]))

    unread_count = Messaging.get_unread_count(socket.assigns.current_user.id)

    unread_counts =
      Helpers.calculate_unread_counts(conversations_filtered, socket.assigns.current_user.id)

    # Sort conversations with unread ones first
    conversations =
      Helpers.sort_conversations_by_unread(
        conversations_filtered,
        unread_counts,
        socket.assigns.current_user.id
      )

    # Calculate read status for last messages
    last_message_read_status =
      Helpers.calculate_last_message_read_status(conversations, socket.assigns.current_user.id)

    joined_servers = Messaging.list_servers(socket.assigns.current_user.id)

    # Re-filter conversations if search is active
    filtered_conversations =
      refresh_conversation_filter(
        conversations,
        socket.assigns.search.conversation_query,
        socket.assigns.current_user.id,
        socket.assigns[:active_server_id]
      )

    {:noreply,
     socket
     |> assign(:conversation, %{
       socket.assigns.conversation
       | list: conversations,
         filtered: filtered_conversations,
         unread_count: unread_count,
         unread_counts: unread_counts,
         last_message_read_status: last_message_read_status
     })
     |> assign(:joined_servers, joined_servers)
     |> assign(:refresh_conversations_scheduled, false)}
  end

  @impl true
  def handle_info(:clear_typing, socket) do
    # Clear own typing indicator
    case socket.assigns.conversation.selected do
      nil ->
        {:noreply, socket}

      conversation ->
        Phoenix.PubSub.broadcast_from(
          Elektrine.PubSub,
          self(),
          "conversation:#{conversation.id}",
          {:user_stopped_typing, socket.assigns.current_user.id}
        )

        Elektrine.Messaging.Federation.publish_typing_stopped(
          conversation.id,
          socket.assigns.current_user.id
        )

        {:noreply, assign(socket, :typing_timer, nil)}
    end
  end

  def handle_info({:user_typing, user_id, username}, socket) do
    # Add user to typing list if not already present
    typing_users = socket.assigns.message.typing_users
    current_time = System.system_time(:second)

    # Clean up stale typing indicators (older than 5 seconds)
    typing_users =
      Enum.filter(typing_users, fn u ->
        current_time - u.started_at < 5
      end)

    if Enum.any?(typing_users, fn u -> u.id == user_id end) do
      # User already in typing list, just update the timestamp
      updated_typing =
        Enum.map(typing_users, fn u ->
          if u.id == user_id do
            %{id: user_id, username: username, started_at: current_time}
          else
            u
          end
        end)

      {:noreply,
       assign(socket, :message, %{socket.assigns.message | typing_users: updated_typing})}
    else
      # Add new user to typing list
      new_typing_user = %{id: user_id, username: username, started_at: current_time}

      {:noreply,
       assign(socket, :message, %{
         socket.assigns.message
         | typing_users: [new_typing_user | typing_users]
       })}
    end
  end

  def handle_info({:user_stopped_typing, user_id}, socket) do
    # Remove user from typing list
    typing_users = Enum.reject(socket.assigns.message.typing_users, fn u -> u.id == user_id end)
    {:noreply, assign(socket, :message, %{socket.assigns.message | typing_users: typing_users})}
  end

  def handle_info({:new_message_notification, message}, socket) do
    # Keep this path light: update unread state locally and debounce full refreshes.
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == message.conversation_id do
      {:noreply, maybe_schedule_conversation_refresh(socket, 300)}
    else
      unread_counts = socket.assigns.conversation.unread_counts || %{}
      updated_unread_counts = Map.update(unread_counts, message.conversation_id, 1, &(&1 + 1))

      socket =
        socket
        |> assign(:conversation, %{
          socket.assigns.conversation
          | unread_count: (socket.assigns.conversation.unread_count || 0) + 1,
            unread_counts: updated_unread_counts
        })
        |> update_conversation_preview(message)
        |> maybe_schedule_conversation_refresh(500)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:new_email, message}, socket) do
    # Handle email notifications while in chat
    socket =
      push_event(socket, "new_email", %{
        from: extract_email_address(message.from || "Unknown"),
        subject: String.slice(message.subject || "No Subject", 0, 100)
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == message.conversation_id do
      if Enum.any?(socket.assigns.messages, &(&1.id == message.id)) do
        {:noreply, socket}
      else
        # Decrypt the new message before adding it
        decrypted_message = Elektrine.Messaging.Message.decrypt_content(message)
        messages = socket.assigns.messages ++ [decrypted_message]

        # Update read status for the new message
        current_read_status = socket.assigns.message.read_status || %{}
        updated_read_status = Map.put(current_read_status, message.id, [])

        # If this is not my message, mark it as read immediately and clear notification
        if message.sender_id != socket.assigns.current_user.id do
          user_id = socket.assigns.current_user.id

          # Mark conversation as read
          Messaging.mark_as_read(message.conversation_id, user_id)

          # Clear the notification for this message immediately
          Elektrine.Notifications.mark_as_read_by_source(user_id, "message", message.id)

          # Broadcast that I read this message
          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "conversation:#{message.conversation_id}",
            {:user_read_messages, user_id}
          )

          # Also broadcast to all conversation members so their conversation list updates
          members = Messaging.get_conversation_members(message.conversation_id)

          Enum.each(members, fn member ->
            Phoenix.PubSub.broadcast(
              Elektrine.PubSub,
              "user:#{member.user_id}",
              {:user_read_messages_in_conversation,
               %{conversation_id: message.conversation_id, reader_id: user_id}}
            )
          end)
        end

        # Always keep currently viewed conversation unread count at 0.
        updated_unread_counts =
          Map.put(socket.assigns.conversation.unread_counts || %{}, message.conversation_id, 0)

        updated_socket =
          socket
          |> assign(:messages, messages)
          |> assign(:message, %{socket.assigns.message | read_status: updated_read_status})
          |> assign(:newest_message_id, message.id)
          |> assign(:has_more_newer_messages, false)
          |> assign(:conversation, %{
            socket.assigns.conversation
            | unread_counts: updated_unread_counts
          })
          |> update_conversation_preview(decrypted_message)

        # Only trigger scroll if it's the current user's own message
        # For other messages, let the client-side MutationObserver handle it
        updated_socket =
          if message.sender_id == socket.assigns.current_user.id do
            # User sent a message - scroll to show their message
            # If message has media, use delayed scroll to wait for images to load
            if message.media_urls && message.media_urls != [] do
              # Message has media - trigger multiple scroll attempts for image loading
              Process.send_after(self(), {:ensure_scroll_after_media, message.id}, 50)
              Process.send_after(self(), {:ensure_scroll_after_media, message.id}, 200)
              Process.send_after(self(), {:ensure_scroll_after_media, message.id}, 500)
              Process.send_after(self(), {:ensure_scroll_after_media, message.id}, 1000)
              Process.send_after(self(), {:ensure_scroll_after_media, message.id}, 1500)
              updated_socket
            else
              # Text only - immediate scroll is fine
              push_event(updated_socket, "scroll_to_bottom", %{})
            end
          else
            # Someone else sent a message - client will auto-scroll if user is at bottom
            updated_socket
          end

        {:noreply, updated_socket}
      end
    else
      {:noreply, maybe_schedule_conversation_refresh(socket, 200)}
    end
  end

  # Chat message handlers (from ChatMessages module for DMs/groups/channels)
  def handle_info({:new_chat_message, message}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == message.conversation_id do
      if Enum.any?(socket.assigns.messages, &(&1.id == message.id)) do
        {:noreply, socket}
      else
        # ChatMessage is already decrypted from the broadcast
        messages = socket.assigns.messages ++ [message]

        # Update read status for the new message
        current_read_status = socket.assigns.message.read_status || %{}
        updated_read_status = Map.put(current_read_status, message.id, [])

        # If this is not my message, mark it as read immediately
        if message.sender_id != socket.assigns.current_user.id do
          user_id = socket.assigns.current_user.id
          Messaging.mark_chat_messages_read(message.conversation_id, user_id, message.id)
        end

        updated_unread_counts =
          Map.put(socket.assigns.conversation.unread_counts || %{}, message.conversation_id, 0)

        updated_socket =
          socket
          |> assign(:messages, messages)
          |> assign(:message, %{socket.assigns.message | read_status: updated_read_status})
          |> assign(:conversation, %{
            socket.assigns.conversation
            | unread_counts: updated_unread_counts
          })
          |> update_conversation_preview(message)

        # Scroll to bottom
        {:noreply, push_event(updated_socket, "scroll_to_bottom", %{})}
      end
    else
      {:noreply, maybe_schedule_conversation_refresh(socket, 200)}
    end
  end

  def handle_info(:room_presence_heartbeat, socket) do
    {:noreply, refresh_room_presence_tracking(socket)}
  end

  def handle_info(:resume_active_call, socket) do
    {:noreply, maybe_resume_active_call(socket)}
  end

  def handle_info(info, socket) do
    case MessageInfoOperations.route_info(info, socket) do
      {:handled, result} ->
        result

      :unhandled ->
        case CallInfoOperations.route_info(info, socket) do
          {:handled, result} -> result
          :unhandled -> {:noreply, socket}
        end
    end
  end

  defp chat_overlay_panels(assigns) do
    ~H"""
    <!-- Server Creation Modal -->
    <%= if @ui.show_server_modal do %>
      <div class="modal modal-open">
        <div
          class="modal-box card glass-card p-6 max-w-md w-full mx-4"
          phx-click-away="hide_create_server"
        >
          <div class="flex justify-between items-center mb-6">
            <h2 class="text-xl font-bold">Create Server</h2>
            <button phx-click="hide_create_server" class="btn btn-ghost btn-sm btn-circle">
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>

          <form phx-submit="create_server" class="space-y-4">
            <div>
              <label class="label">
                <span class="label-text font-semibold">Server Name</span>
              </label>
              <input
                type="text"
                name="server[name]"
                placeholder="Server name"
                class="input input-bordered w-full"
                required
                autofocus
              />
            </div>

            <div>
              <label class="label">
                <span class="label-text font-semibold">Description</span>
              </label>
              <textarea
                name="server[description]"
                placeholder="What is this server about? (optional)"
                class="textarea textarea-bordered w-full"
                rows="3"
              ></textarea>
            </div>

            <div>
              <label class="label">
                <span class="label-text font-semibold">Server Icon</span>
              </label>
              <div class="flex items-center gap-3">
                <%= if @uploads.server_icon_upload.entries != [] do %>
                  <% entry = List.first(@uploads.server_icon_upload.entries) %>
                  <div class="w-14 h-14 rounded-xl overflow-hidden bg-base-200 border border-base-300">
                    <.live_img_preview entry={entry} class="w-full h-full object-cover" />
                  </div>
                <% else %>
                  <div class="w-14 h-14 rounded-xl bg-base-200 border border-dashed border-base-300 flex items-center justify-center">
                    <.icon name="hero-photo" class="w-6 h-6 text-base-content/60" />
                  </div>
                <% end %>
                <label class="btn btn-ghost btn-sm">
                  Choose Image
                  <.live_file_input
                    upload={@uploads.server_icon_upload}
                    class="hidden"
                    phx-change="validate_upload"
                  />
                </label>
              </div>
              <%= for entry <- @uploads.server_icon_upload.entries do %>
                <div class="mt-2 flex items-center gap-2 text-xs">
                  <span class="truncate flex-1">{entry.client_name}</span>
                  <progress
                    class="progress progress-secondary w-28 h-2"
                    value={entry.progress}
                    max="100"
                  >
                  </progress>
                  <button
                    type="button"
                    phx-click="cancel_upload"
                    phx-value-ref={entry.ref}
                    phx-value-upload_name="server_icon_upload"
                    class="btn btn-ghost btn-xs btn-circle"
                    title="Remove image"
                  >
                    <.icon name="hero-x-mark" class="w-3 h-3" />
                  </button>
                </div>
              <% end %>
            </div>

            <div>
              <label class="label cursor-pointer justify-start gap-3">
                <input
                  type="checkbox"
                  name="server[is_public]"
                  value="true"
                  class="checkbox checkbox-primary"
                />
                <span class="label-text">Show in server directory</span>
              </label>
              <p class="text-xs text-base-content/70 mt-1">
                Public servers are discoverable and users can request membership.
              </p>
            </div>

            <div class="flex gap-3 pt-2">
              <button type="submit" class="btn btn-secondary flex-1">
                <.icon name="hero-plus-circle" class="w-4 h-4 mr-2" /> Create Server
              </button>
              <button type="button" phx-click="hide_create_server" class="btn btn-ghost">
                Cancel
              </button>
            </div>
          </form>
        </div>
      </div>
    <% end %>

    <!-- Settings Modal -->
    <%= if @ui.show_settings_modal && @conversation.selected do %>
      <div class="modal modal-open">
        <div
          class="modal-box card glass-card p-6 max-w-md w-full mx-4"
          phx-click-away="hide_settings"
        >
          <div class="flex justify-between items-center mb-6">
            <h2 class="text-xl font-bold">
              {conversation_type_label(@conversation.selected.type)} Settings
            </h2>
            <button phx-click="hide_settings" class="btn btn-ghost btn-sm">
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
          
    <!-- Chat Details -->
          <div class="space-y-4">
            <div>
              <label class="label">
                <span class="label-text font-semibold">Name</span>
              </label>
              <p class="text-sm bg-base-200 p-2 rounded">
                {route_label(@conversation.selected, @current_user.id)}
              </p>
            </div>

            <%= if @conversation.selected.description do %>
              <div>
                <label class="label">
                  <span class="label-text font-semibold">Description</span>
                </label>
                <p class="text-sm bg-base-200 p-2 rounded">
                  {@conversation.selected.description}
                </p>
              </div>
            <% end %>

            <div>
              <label class="label">
                <span class="label-text font-semibold">Type</span>
              </label>
              <div class="flex items-center gap-2">
                <%= case @conversation.selected.type do %>
                  <% "group" -> %>
                    <.icon name="hero-users" class="w-4 h-4" />
                    <span class="text-sm">
                      {if @conversation.selected.is_public, do: "Public", else: "Private"} Group
                    </span>
                  <% "channel" -> %>
                    <.icon name="hero-megaphone" class="w-4 h-4" />
                    <span class="text-sm">
                      <%= if @conversation.selected.server_id do %>
                        {if @conversation.selected.is_public, do: "Server", else: "Private Server"} Channel
                      <% else %>
                        {if @conversation.selected.is_public, do: "Public", else: "Private"} Channel
                      <% end %>
                    </span>
                  <% _ -> %>
                    <.icon name="hero-user" class="w-4 h-4" />
                    <span class="text-sm">Direct Message</span>
                <% end %>
              </div>
            </div>

            <div>
              <label class="label">
                <span class="label-text font-semibold">Members</span>
              </label>
              <p class="text-sm bg-base-200 p-2 rounded">
                {@conversation.selected.member_count} members
              </p>
            </div>

            <%= if @conversation.selected.creator_id do %>
              <div>
                <label class="label">
                  <span class="label-text font-semibold">Created by</span>
                </label>
                <% creator =
                  Enum.find(
                    @conversation.selected.members,
                    &(&1.user_id == @conversation.selected.creator_id)
                  ) %>
                <%= if creator do %>
                  <p class="text-sm bg-base-200 p-2 rounded">
                    {user_at_handle(creator.user)}
                  </p>
                <% end %>
              </div>
            <% end %>
          </div>
          
    <!-- Danger Zone for Admins -->
          <% current_member =
            Enum.find(
              @conversation.selected.members,
              &(&1.user_id == @current_user.id and is_nil(&1.left_at))
            ) %>
          <%= if current_member && current_member.role == "admin" && @conversation.selected.type != "dm" do %>
            <div class="divider text-error">Admin Actions</div>
            <div class="space-y-2">
              <button
                phx-click="show_edit_conversation"
                class="btn btn-sm btn-ghost w-full"
              >
                <.icon name="hero-pencil" class="w-4 h-4 mr-2" />
                Edit {conversation_type_label(@conversation.selected.type)}
              </button>
              <%= if @conversation.selected.creator_id == @current_user.id do %>
                <button
                  phx-click="delete_conversation"
                  class="btn btn-sm btn-secondary btn-ghost w-full"
                  data-confirm={
                    "Are you sure you want to delete this #{conversation_type_label_lower(@conversation.selected.type)}? This action cannot be undone."
                  }
                >
                  <.icon name="hero-trash" class="w-4 h-4 mr-2" />
                  Delete {conversation_type_label(@conversation.selected.type)}
                </button>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>

    <!-- Edit Conversation Modal -->
    <%= if @ui.show_edit_modal && @conversation.selected do %>
      <div class="modal modal-open">
        <div
          class="modal-box card glass-card p-6 max-w-md w-full mx-4"
          phx-click-away="hide_edit_conversation"
        >
          <div class="flex justify-between items-center mb-6">
            <h2 class="text-xl font-bold">
              Edit {conversation_type_label(@conversation.selected.type)}
            </h2>
            <button phx-click="hide_edit_conversation" class="btn btn-ghost btn-sm">
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <.form for={%{}} phx-submit="update_conversation" class="space-y-4">
            <div>
              <label class="label">
                <span class="label-text font-semibold">Name</span>
              </label>
              <input
                type="text"
                name="conversation[name]"
                value={@form.edit_name}
                placeholder="Name"
                class="input input-bordered w-full"
                required
              />
            </div>

            <div>
              <label class="label">
                <span class="label-text font-semibold">Description</span>
              </label>
              <textarea
                name="conversation[description]"
                placeholder="Description (optional)"
                class="textarea textarea-bordered w-full"
                rows="3"
              >{@form.edit_description}</textarea>
            </div>

            <%= if @conversation.selected.type == "group" do %>
              <div class="form-control">
                <label class="label cursor-pointer">
                  <span class="label-text">Make Public</span>
                  <input type="hidden" name="conversation[is_public]" value="false" />
                  <input
                    type="checkbox"
                    name="conversation[is_public]"
                    value="true"
                    checked={@conversation.selected.is_public}
                    class="checkbox"
                  />
                </label>
                <div class="label">
                  <span class="label-text-alt">
                    Anyone can find and join this public group
                  </span>
                </div>
              </div>
            <% end %>

            <%= if @conversation.selected.type == "channel" && @conversation.selected.server_id do %>
              <div class="form-control">
                <label class="label cursor-pointer">
                  <span class="label-text">Private Channel</span>
                  <input type="hidden" name="conversation[is_private]" value="false" />
                  <input
                    type="checkbox"
                    name="conversation[is_private]"
                    value="true"
                    checked={!@conversation.selected.is_public}
                    class="checkbox"
                  />
                </label>
                <div class="label">
                  <span class="label-text-alt">
                    Restrict this channel. Public server channels are visible to all server members.
                  </span>
                </div>
              </div>
            <% end %>

            <%= if @conversation.selected.type == "channel" && is_nil(@conversation.selected.server_id) do %>
              <div class="form-control">
                <label class="label cursor-pointer">
                  <span class="label-text">Make Public</span>
                  <input type="hidden" name="conversation[is_public]" value="false" />
                  <input
                    type="checkbox"
                    name="conversation[is_public]"
                    value="true"
                    checked={@conversation.selected.is_public}
                    class="checkbox"
                  />
                </label>
                <div class="label">
                  <span class="label-text-alt">
                    Anyone can find and join this public channel
                  </span>
                </div>
              </div>
            <% end %>

            <div class="flex gap-2">
              <button type="submit" class="btn btn-secondary flex-1">
                <.icon name="hero-check" class="w-4 h-4 mr-2" /> Save Changes
              </button>
              <button
                type="button"
                phx-click="hide_edit_conversation"
                class="btn btn-ghost"
              >
                Cancel
              </button>
            </div>
          </.form>
        </div>
      </div>
    <% end %>

    <!-- Add Members Modal -->
    <%= if @ui.show_add_members_modal && @conversation.selected do %>
      <div class="modal modal-open">
        <div
          class="modal-box card glass-card p-6 max-w-md w-full mx-4"
          phx-click-away="hide_add_members"
        >
          <div class="flex justify-between items-center mb-6">
            <h2 class="text-xl font-bold">
              Add Members to {route_label(@conversation.selected, @current_user.id)}
            </h2>
            <button phx-click="hide_add_members" class="btn btn-ghost btn-sm">
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <div class="space-y-4">
            <%= if @pending_remote_join_requests != [] do %>
              <div class="space-y-3">
                <div>
                  <p class="text-sm font-semibold">Pending Remote Join Requests</p>
                  <p class="text-xs opacity-70">
                    Review remote participants waiting for room approval.
                  </p>
                </div>

                <div class="space-y-2">
                  <%= for request <- @pending_remote_join_requests do %>
                    <div class="flex items-center justify-between gap-3 p-3 bg-base-200 rounded-lg">
                      <div class="flex items-center gap-3 min-w-0">
                        <div class="w-8 h-8 rounded-full overflow-hidden bg-base-300 flex items-center justify-center shrink-0">
                          <%= if request.avatar_url do %>
                            <img
                              src={request.avatar_url}
                              alt={request.display_label}
                              class="w-full h-full object-cover"
                            />
                          <% else %>
                            <.icon name="hero-globe-alt" class="w-4 h-4 opacity-60" />
                          <% end %>
                        </div>
                        <div class="min-w-0">
                          <p class="font-medium text-sm truncate">{request.display_label}</p>
                          <p class="text-xs opacity-70 truncate">
                            Requested role: {request.role} · {request.origin_domain}
                          </p>
                        </div>
                      </div>

                      <div class="flex items-center gap-2 shrink-0">
                        <button
                          phx-click="approve_remote_join_request"
                          phx-value-remote_actor_id={request.remote_actor_id}
                          class="btn btn-success btn-xs"
                        >
                          Approve
                        </button>
                        <button
                          phx-click="decline_remote_join_request"
                          phx-value-remote_actor_id={request.remote_actor_id}
                          class="btn btn-ghost btn-xs"
                        >
                          Decline
                        </button>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
            
    <!-- User Search -->
            <input
              type="text"
              placeholder="Search users to add..."
              value={@search.query}
              phx-keyup="search_users"
              phx-debounce="300"
              class="input input-bordered w-full"
              name="query"
            />
            
    <!-- Search Results -->
            <%= if @search.results != [] do %>
              <div class="max-h-64 overflow-y-auto space-y-2">
                <%= for user <- @search.results do %>
                  <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg">
                    <button
                      phx-click="show_user_profile"
                      phx-value-user_id={user.id}
                      class="flex items-center gap-3 flex-1 text-left hover:opacity-75 cursor-pointer"
                    >
                      <div class="w-8 h-8 rounded-full overflow-visible">
                        <.user_avatar user={user} size="sm" user_statuses={@user_statuses} />
                      </div>
                      <div>
                        <p class="font-medium text-sm">
                          <.username_with_effects
                            user={user}
                            display_name={true}
                            verified_size="xs"
                          />
                        </p>
                        <p class="text-xs opacity-70">{user_at_handle(user)}</p>
                      </div>
                    </button>
                    <button
                      phx-click="add_member_to_conversation"
                      phx-value-user_id={user.id}
                      class="btn btn-secondary btn-xs"
                    >
                      Add
                    </button>
                  </div>
                <% end %>
              </div>
            <% else %>
              <div class="text-center py-8">
                <.icon name="hero-magnifying-glass" class="w-8 h-8 mx-auto opacity-50 mb-2" />
                <p class="text-sm opacity-70">Search for users to add</p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>

    <!-- Message Search Modal -->
    <%= if @ui.show_message_search_modal && @conversation.selected do %>
      <div class="modal modal-open">
        <div
          class="modal-box card glass-card p-6 max-w-lg w-full mx-4"
          phx-click-away="hide_message_search"
        >
          <div class="flex justify-between items-center mb-6">
            <h2 class="text-xl font-bold">
              Search Messages in {route_label(
                @conversation.selected,
                @current_user.id
              )}
            </h2>
            <button phx-click="hide_message_search" class="btn btn-ghost btn-sm">
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <div class="space-y-4">
            <!-- Message Search -->
            <input
              type="text"
              placeholder="Search message content..."
              value={@search.message_query}
              phx-keyup="search_messages"
              phx-debounce="300"
              class="input input-bordered w-full"
              name="query"
            />
            
    <!-- Search Results -->
            <%= if @search.message_results != [] do %>
              <div class="max-h-96 overflow-y-auto space-y-2">
                <%= for message <- @search.message_results do %>
                  <div class="p-3 bg-base-200 rounded-lg">
                    <div class="flex items-center gap-2 mb-2">
                      <div class="w-6 h-6 rounded-lg overflow-visible">
                        <.user_avatar
                          user={message_sender(message)}
                          size="xs"
                          user_statuses={@user_statuses}
                        />
                      </div>
                      <span class="text-sm font-medium">
                        {message_sender_tag(message)}
                      </span>
                      <span class="text-xs opacity-70">
                        <.local_time
                          datetime={message.inserted_at}
                          format="datetime"
                          timezone={@timezone}
                          time_format={@time_format}
                        />
                      </span>
                    </div>
                    <p class="text-sm">{message.content}</p>
                  </div>
                <% end %>
              </div>
            <% else %>
              <div class="text-center py-8">
                <.icon name="hero-chat-bubble-left" class="w-8 h-8 mx-auto opacity-50 mb-2" />
                <p class="text-sm opacity-70">
                  <%= if @search.message_query == "" do %>
                    Type to search messages
                  <% else %>
                    No messages found
                  <% end %>
                </p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>

    <!-- Context Menu -->
    <%= if @context_menu.conversation do %>
      <div
        class="fixed bg-base-100 border border-base-300 rounded-lg shadow-xl z-50 py-2 min-w-48 animate-fade-in"
        style={"left: #{@context_menu.position.x}px; top: #{@context_menu.position.y}px;"}
        phx-click-away="hide_context_menu"
      >
        <% member =
          Enum.find(
            @context_menu.conversation.members,
            &(&1.user_id == @current_user.id and is_nil(&1.left_at))
          ) %>
        
    <!-- Pin/Unpin -->
        <%= if member && member.pinned do %>
          <button
            phx-click="unpin_conversation"
            phx-value-conversation_id={@context_menu.conversation.id}
            class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2"
          >
            <.icon name="hero-bookmark" class="w-4 h-4" /> Unpin
          </button>
        <% else %>
          <button
            phx-click="pin_conversation"
            phx-value-conversation_id={@context_menu.conversation.id}
            class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2"
          >
            <.icon name="hero-bookmark" class="w-4 h-4" /> Pin to Top
          </button>
        <% end %>
        
    <!-- Mark as Read -->
        <button
          phx-click="mark_as_read"
          phx-value-conversation_id={@context_menu.conversation.id}
          class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2"
        >
          <.icon name="hero-check-circle" class="w-4 h-4" /> Mark as Read
        </button>

        <div class="divider my-1"></div>
        
    <!-- Clear History -->
        <button
          phx-click="clear_history"
          phx-value-conversation_id={@context_menu.conversation.id}
          data-confirm="Clear your message history in this chat? This cannot be undone."
          class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2 text-warning"
        >
          <.icon name="hero-trash" class="w-4 h-4" /> Clear History
        </button>
        
    <!-- Leave (for groups/channels) -->
        <%= if @context_menu.conversation.type != "dm" do %>
          <button
            phx-click="leave_conversation"
            data-confirm={
              "Are you sure you want to leave this #{conversation_type_label_lower(@context_menu.conversation.type)}?"
            }
            class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2 text-error"
          >
            <.icon name="hero-arrow-left-on-rectangle" class="w-4 h-4" />
            Leave {conversation_type_label(@context_menu.conversation.type)}
          </button>
        <% end %>
      </div>
    <% end %>

    <!-- Message Context Menu -->
    <%= if @context_menu.message do %>
      <div
        class="fixed bg-base-100 border border-base-300 rounded-lg shadow-xl z-50 py-2 min-w-48 animate-fade-in"
        style={"left: #{@context_menu.position.x}px; top: #{@context_menu.position.y}px;"}
        phx-click-away="hide_message_context_menu"
      >
        <!-- Copy Message -->
        <button
          phx-click="copy_message"
          phx-value-message_id={@context_menu.message.id}
          class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2"
        >
          <.icon name="hero-clipboard" class="w-4 h-4" /> Copy Message
        </button>
        
    <!-- Reply to Message -->
        <button
          phx-click="reply_to_message"
          phx-value-message_id={@context_menu.message.id}
          class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2"
        >
          <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> Reply
        </button>
        
    <!-- Pin/Unpin Message -->
        <%= if Map.get(@context_menu.message, :is_pinned, false) do %>
          <button
            phx-click="unpin_message"
            phx-value-message_id={@context_menu.message.id}
            class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2"
          >
            <.icon name="hero-bookmark-slash" class="w-4 h-4" /> Unpin Message
          </button>
        <% else %>
          <button
            phx-click="pin_message"
            phx-value-message_id={@context_menu.message.id}
            class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2"
          >
            <.icon name="hero-bookmark" class="w-4 h-4" /> Pin Message
          </button>
        <% end %>

        <%= if @context_menu.message.sender_id == @current_user.id do %>
          <div class="divider my-1"></div>
          
    <!-- Delete Own Message -->
          <button
            phx-click="delete_message"
            phx-value-message_id={@context_menu.message.id}
            data-confirm="Delete this message?"
            class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2 text-error"
          >
            <.icon name="hero-trash" class="w-4 h-4" /> Delete Message
          </button>
        <% end %>

        <%= if @current_user.is_admin do %>
          <div class="divider my-1"></div>

          <div class="px-4 py-1 text-xs font-bold text-warning">
            Admin Actions
          </div>
          
    <!-- Delete Message -->
          <button
            phx-click="delete_message_admin"
            phx-value-message_id={@context_menu.message.id}
            data-confirm="Delete this message?"
            class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2 text-error"
          >
            <.icon name="hero-trash" class="w-4 h-4" /> Delete Message
          </button>

          <%= if is_integer(@context_menu.message.sender_id) do %>
            <!-- Timeout User -->
            <button
              phx-click="timeout_user"
              phx-value-user_id={@context_menu.message.sender_id}
              phx-value-duration="300"
              class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2 text-warning"
            >
              <.icon name="hero-clock" class="w-4 h-4" /> Timeout User (5min)
            </button>
            
    <!-- Timeout User 1hr -->
            <button
              phx-click="timeout_user"
              phx-value-user_id={@context_menu.message.sender_id}
              phx-value-duration="3600"
              class="w-full px-4 py-2 text-left hover:bg-base-200 flex items-center gap-2 text-warning"
            >
              <.icon name="hero-clock" class="w-4 h-4" /> Timeout User (1hr)
            </button>
          <% end %>
        <% end %>
      </div>
    <% end %>

    <!-- User Profile Modal -->
    <%= if @ui.show_profile_modal && @profile_user do %>
      <div class="modal modal-open">
        <div
          class="modal-box card glass-card p-6 max-w-md w-full mx-4"
          phx-click-away="hide_profile_modal"
        >
          <div class="flex justify-between items-center mb-6">
            <h2 class="text-xl font-bold">User Profile</h2>
            <button phx-click="hide_profile_modal" class="btn btn-ghost btn-sm">
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>
          
    <!-- User Info -->
          <div class="text-center mb-6">
            <button
              data-external-link={
                if @profile_user.profile,
                  do:
                    "https://#{@profile_user.handle || @profile_user.username}.#{Elektrine.Domains.primary_profile_domain()}",
                  else: "/#{@profile_user.handle || @profile_user.username}"
              }
              class="avatar mb-4 cursor-pointer"
              title="View full profile"
            >
              <div class="w-20 h-20 rounded-lg">
                <.user_avatar user={@profile_user} size="2xl" />
              </div>
            </button>

            <h3 class="text-lg font-medium">
              <.username_with_effects user={@profile_user} display_name={true} verified_size="md" />
            </h3>
            <p class="text-sm opacity-70 mb-4">{user_at_handle(@profile_user)}</p>

            <%= if Ecto.assoc_loaded?(@profile_user.profile) && @profile_user.profile && @profile_user.profile.description do %>
              <div class="bg-base-200 rounded-lg p-3 mb-4">
                <p class="text-sm">{@profile_user.profile.description}</p>
              </div>
            <% end %>

            <%= if Ecto.assoc_loaded?(@profile_user.profile) && @profile_user.profile && @profile_user.profile.location do %>
              <div class="flex items-center justify-center gap-2 mb-4">
                <.icon name="hero-map-pin" class="w-4 h-4 opacity-70" />
                <span class="text-sm opacity-70">{@profile_user.profile.location}</span>
              </div>
            <% end %>
          </div>
          
    <!-- Action Buttons -->
          <div class="space-y-3">
            <!-- View Full Profile -->
            <button
              data-external-link={
                if @profile_user.profile,
                  do:
                    "https://#{@profile_user.handle || @profile_user.username}.#{Elektrine.Domains.primary_profile_domain()}",
                  else: "/#{@profile_user.handle || @profile_user.username}"
              }
              class="btn btn-ghost w-full"
            >
              <.icon name="hero-user" class="w-4 h-4 mr-2" /> View Full Profile
            </button>

            <%= if @profile_user.id != @current_user.id do %>
              <!-- Start DM -->
              <button
                phx-click="start_dm"
                phx-value-user_id={@profile_user.id}
                class="btn btn-secondary w-full"
              >
                <.icon name="hero-chat-bubble-left-right" class="w-4 h-4 mr-2" /> Send Message
              </button>
              
    <!-- Block/Unblock User -->
              <%= if Elektrine.Accounts.user_blocked?(@current_user.id, @profile_user.id) do %>
                <button
                  phx-click="unblock_user"
                  phx-value-user_id={@profile_user.id}
                  class="btn btn-success btn-ghost w-full"
                >
                  <.icon name="hero-check" class="w-4 h-4 mr-2" /> Unblock User
                </button>
              <% else %>
                <button
                  phx-click="block_user"
                  phx-value-user_id={@profile_user.id}
                  class="btn btn-secondary btn-ghost w-full"
                  data-confirm="Are you sure you want to block this user?"
                >
                  <.icon name="hero-no-symbol" class="w-4 h-4 mr-2" /> Block User
                </button>
              <% end %>
              
    <!-- Report User -->
              <button
                phx-click="show_report_modal"
                phx-value-type="user"
                phx-value-id={@profile_user.id}
                class="btn btn-warning btn-ghost w-full"
              >
                <.icon name="hero-flag" class="w-4 h-4 mr-2" /> Report User
              </button>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>

    <!-- Browse Network Modal -->
    <%= if @ui.show_browse_modal do %>
      <div class="modal modal-open">
        <div
          class="modal-box card glass-card w-[95vw] max-w-6xl mx-4 max-h-[85vh] overflow-hidden"
          phx-click-away="hide_browse_modal"
        >
          <div class="flex items-center justify-between p-4 border-b border-base-300">
            <h2 class="text-xl font-bold">Explore Servers and Groups</h2>
            <button phx-click="hide_browse_modal" class="btn btn-ghost btn-sm">
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
          </div>

          <div class="p-4">
            <!-- Tab Navigation -->
            <div class="tabs tabs-bordered mb-4">
              <button
                phx-click="browse_tab"
                phx-value-tab="servers"
                class={["tab", @browse.tab == "servers" && "tab-active"]}
              >
                <.icon name="hero-globe-alt" class="w-4 h-4 mr-2" /> Servers
              </button>
              <button
                phx-click="browse_tab"
                phx-value-tab="groups"
                class={["tab", @browse.tab == "groups" && "tab-active"]}
              >
                <.icon name="hero-users" class="w-4 h-4 mr-2" /> Public Groups
              </button>
            </div>
            
    <!-- Search Bar -->
            <div class="mb-4">
              <input
                type="text"
                placeholder={
                  case @browse.tab do
                    "servers" -> "Search servers..."
                    _ -> "Search groups..."
                  end
                }
                class="input input-bordered w-full"
                value={@search.browse_query}
                phx-debounce="300"
                phx-change="browse_search"
                name="search"
              />
            </div>
            
    <!-- Content Area -->
            <div class="max-h-96 overflow-y-auto">
              <%= if @browse.tab == "servers" do %>
                <%= if @browse.filtered_servers == [] do %>
                  <div class="text-center py-8">
                    <.icon name="hero-globe-alt" class="w-8 h-8 mx-auto opacity-50 mb-2" />
                    <p class="text-sm opacity-70">No servers found</p>
                    <p class="text-xs opacity-50">Check back soon for newly shared servers.</p>
                  </div>
                <% else %>
                  <div class="space-y-2">
                    <%= for server <- @browse.filtered_servers do %>
                      <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg">
                        <div class="flex-1 min-w-0">
                          <div class="flex items-center gap-2">
                            <.icon name="hero-globe-alt" class="w-4 h-4 opacity-70" />
                            <p class="font-medium text-sm truncate">{server.name}</p>
                            <%= if server.is_federated_mirror do %>
                              <span class="badge badge-secondary badge-xs">
                                From another server
                              </span>
                            <% end %>
                          </div>
                          <%= if server.description do %>
                            <p class="text-xs opacity-70 truncate mt-1">{server.description}</p>
                          <% end %>
                          <div class="flex items-center gap-4 mt-1">
                            <span class="text-xs opacity-60">
                              {server.member_count} members
                            </span>
                            <span class="text-xs opacity-60">
                              {if server.origin_domain,
                                do: "from #{server.origin_domain}",
                                else: "created here"}
                            </span>
                            <span class="text-xs opacity-60">
                              {if server.creator,
                                do: "by @#{server.creator.username}",
                                else: "shared server"}
                            </span>
                          </div>
                        </div>
                        <button
                          phx-click="join_server"
                          phx-value-server_id={server.id}
                          class="btn btn-primary btn-sm"
                        >
                          Join Server
                        </button>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              <% else %>
                <%= if @browse.filtered_groups == [] do %>
                  <div class="text-center py-8">
                    <.icon name="hero-users" class="w-8 h-8 mx-auto opacity-50 mb-2" />
                    <p class="text-sm opacity-70">No public groups found</p>
                    <p class="text-xs opacity-50">Create the first public group chat.</p>
                  </div>
                <% else %>
                  <div class="space-y-2">
                    <%= for group <- @browse.filtered_groups do %>
                      <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg">
                        <div class="flex-1 min-w-0">
                          <div class="flex items-center gap-2">
                            <.icon name="hero-users" class="w-4 h-4 opacity-70" />
                            <p class="font-medium text-sm truncate">{group.name}</p>
                          </div>
                          <%= if group.description do %>
                            <p class="text-xs opacity-70 truncate mt-1">{group.description}</p>
                          <% end %>
                          <div class="flex items-center gap-4 mt-1">
                            <span class="text-xs opacity-60">
                              {group.member_count} members
                            </span>
                            <span class="text-xs opacity-60">
                              by {user_at_handle(group.creator)}
                            </span>
                          </div>
                        </div>
                        <button
                          phx-click="join_group"
                          phx-value-group_id={group.id}
                          class="btn btn-primary btn-sm"
                        >
                          Join Group
                        </button>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    <% end %>

    <!-- Member Management Modal -->
    <%= if assigns[:show_member_management] && @ui.show_member_management do %>
      <div
        class="modal modal-open"
        phx-click="hide_member_management"
      >
        <div
          class="card glass-card bg-base-100 rounded-xl shadow-xl w-full max-w-2xl max-h-[80vh] overflow-hidden"
          phx-click="ignore"
        >
          <div class="p-6 border-b border-base-300">
            <div class="flex items-center justify-between">
              <h3 class="text-lg font-semibold flex items-center">
                <.icon name="hero-users" class="w-5 h-5 mr-2" /> Manage Members
              </h3>
              <button
                phx-click="hide_member_management"
                class="btn btn-ghost btn-sm btn-circle"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
          </div>

          <div class="overflow-y-auto max-h-96 p-6">
            <%= if @conversation.selected && @conversation.selected.members do %>
              <div class="space-y-3">
                <%= for member <- @conversation.selected.members do %>
                  <%= if is_nil(member.left_at) do %>
                    <div class="flex items-center justify-between p-3 bg-base-200 rounded-lg">
                      <div class="flex items-center gap-3">
                        <div class="w-10 h-10 rounded-full overflow-visible">
                          <.user_avatar user={member.user} size="sm" user_statuses={@user_statuses} />
                        </div>
                        <div>
                          <p class="font-medium">
                            <.username_with_effects
                              user={member.user}
                              display_name={true}
                              verified_size="xs"
                            />
                          </p>
                          <p class="text-sm opacity-70">
                            {user_at_handle(member.user)}
                          </p>
                          <%= if member.user.is_admin do %>
                            <div class="badge badge-warning badge-xs">Admin</div>
                          <% end %>
                          <%= if member.role == "admin" do %>
                            <div class="badge badge-error badge-xs">Chat Admin</div>
                          <% end %>
                        </div>
                      </div>

                      <%= if (@current_user.is_admin or Helpers.conversation_admin?(@conversation.selected, @current_user)) && member.user_id != @current_user.id do %>
                        <div class="flex gap-2">
                          <%= if Map.get(@moderation.user_timeout_status, member.user_id, false) do %>
                            <button
                              phx-click="remove_timeout_user"
                              phx-value-user_id={member.user_id}
                              class="btn btn-xs btn-success"
                              title="Remove Timeout"
                            >
                              <.icon name="hero-clock" class="w-3 h-3" />
                            </button>
                          <% else %>
                            <div class="dropdown dropdown-end">
                              <button tabindex="0" class="btn btn-xs btn-warning">
                                <.icon name="hero-shield-exclamation" class="w-3 h-3" />
                              </button>
                              <ul
                                tabindex="0"
                                class="dropdown-content z-30 menu p-2 shadow-lg bg-base-100 rounded-box w-36 z-30"
                              >
                                <li>
                                  <button
                                    phx-click="timeout_user"
                                    phx-value-user_id={member.user_id}
                                    phx-value-duration="300"
                                    class="text-xs"
                                  >
                                    Timeout 5min
                                  </button>
                                </li>
                                <li>
                                  <button
                                    phx-click="timeout_user"
                                    phx-value-user_id={member.user_id}
                                    phx-value-duration="3600"
                                    class="text-xs"
                                  >
                                    Timeout 1hr
                                  </button>
                                </li>
                              </ul>
                            </div>
                          <% end %>

                          <button
                            phx-click="kick_user"
                            phx-value-user_id={member.user_id}
                            class="btn btn-xs btn-secondary"
                            data-confirm="Are you sure you want to kick this user?"
                            title="Kick User"
                          >
                            <.icon name="hero-user-minus" class="w-3 h-3" />
                          </button>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>

    <!-- Moderation Log Modal -->
    <%= if assigns[:show_moderation_log] && @ui.show_moderation_log do %>
      <div
        class="modal modal-open"
        phx-click="hide_moderation_log"
      >
        <div
          class="card glass-card bg-base-100 rounded-xl shadow-xl w-full max-w-4xl max-h-[80vh] overflow-hidden"
          phx-click="ignore"
        >
          <div class="p-6 border-b border-base-300">
            <div class="flex items-center justify-between">
              <h3 class="text-lg font-semibold flex items-center">
                <.icon name="hero-clipboard-document-list" class="w-5 h-5 mr-2" /> Moderation Log
              </h3>
              <button
                phx-click="hide_moderation_log"
                class="btn btn-ghost btn-sm btn-circle"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>
          </div>

          <div class="overflow-y-auto max-h-96 p-6">
            <%= if @moderation.log == [] do %>
              <div class="text-center py-8 opacity-70">
                <.icon name="hero-clipboard-document-list" class="w-16 h-16 mx-auto mb-4" />
                <p>No moderation actions recorded</p>
              </div>
            <% else %>
              <div class="space-y-3">
                <%= for action <- @moderation.log do %>
                  <div class="flex items-start gap-4 p-4 bg-base-200 rounded-lg">
                    <div class="flex-shrink-0">
                      <%= case action.action_type do %>
                        <% "timeout" -> %>
                          <div class="w-8 h-8 bg-warning/20 rounded-lg flex items-center justify-center">
                            <.icon name="hero-clock" class="w-4 h-4 text-warning" />
                          </div>
                        <% "kick" -> %>
                          <div class="w-8 h-8 bg-error/20 rounded-lg flex items-center justify-center">
                            <.icon name="hero-user-minus" class="w-4 h-4 text-error" />
                          </div>
                        <% "delete_message" -> %>
                          <div class="w-8 h-8 bg-error/20 rounded-lg flex items-center justify-center">
                            <.icon name="hero-trash" class="w-4 h-4 text-error" />
                          </div>
                        <% _ -> %>
                          <div class="w-8 h-8 bg-base-300 rounded-lg flex items-center justify-center">
                            <.icon name="hero-shield-exclamation" class="w-4 h-4" />
                          </div>
                      <% end %>
                    </div>

                    <div class="flex-1">
                      <div class="flex items-center gap-2 mb-1">
                        <span class="font-medium">{String.capitalize(action.action_type)}</span>
                        <span class="text-sm opacity-70">
                          <.local_time
                            datetime={action.inserted_at}
                            format="datetime"
                            timezone={@timezone}
                            time_format={@time_format}
                          />
                        </span>
                      </div>

                      <p class="text-sm mb-2">
                        <span class="font-medium">{action.moderator.username}</span>
                        {action.action_type}ed
                        <span class="font-medium">
                          {action.target_user.handle || action.target_user.username}
                        </span>
                        <%= if action.conversation do %>
                          in chat <span class="font-medium">#{action.conversation.name}</span>
                        <% end %>
                        <%= if action.duration do %>
                          for
                          <span class="font-medium">
                            {Helpers.format_duration(action.duration)}
                          </span>
                        <% end %>
                      </p>

                      <%= if action.reason do %>
                        <p class="text-sm opacity-70">
                          <span class="font-medium">Reason:</span> {action.reason}
                        </p>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    <% end %>

    <!-- Report Modal -->
    <%= if @show_report_modal do %>
      <.live_component
        module={ElektrineWeb.Components.ReportModal}
        id="report-modal"
        reporter_id={@current_user.id}
        reportable_type={@report_type}
        reportable_id={@report_id}
        additional_metadata={@report_metadata}
      />
    <% end %>

    <%= if @call.incoming_call do %>
      <.incoming_call_modal call={@call.incoming_call} show={@ui.show_incoming_call} />
    <% end %>

    <%= if @call.active_call do %>
      <.active_call_overlay
        call={@call.active_call}
        show={true}
        audio_enabled={@call.audio_enabled}
        video_enabled={@call.video_enabled}
        call_status={@call.status}
        is_caller={@call.active_call.caller_id == @current_user.id}
      />
    <% end %>
    <!-- Image Modal -->
    <% modal_is_liked = @modal_post && Map.get(assigns[:user_likes] || %{}, @modal_post.id, false)
    modal_like_count = (@modal_post && @modal_post.like_count) || 0 %>
    <.image_modal
      show={@show_image_modal}
      image_url={@modal_image_url}
      images={@modal_images}
      image_index={@modal_image_index}
      post={@modal_post}
      timezone={@timezone}
      time_format={@time_format}
      current_user={@current_user}
      is_liked={modal_is_liked}
      like_count={modal_like_count}
    />
    """
  end

  @impl true
  def terminate(_reason, socket) do
    # Clean up any active calls when user disconnects
    if socket.assigns.call && socket.assigns.call.active_call do
      case socket.assigns.call.active_call do
        %{source: :federated, id: session_id} ->
          VoiceCalls.end_session(session_id, socket.assigns.current_user.id, "disconnected")
          Elektrine.Messaging.Federation.publish_dm_call_end(session_id)

        %{id: call_id} ->
          Calls.end_call(call_id)
      end
    end

    :ok
  end

  defp maybe_schedule_conversation_refresh(socket, delay_ms) do
    if socket.assigns[:refresh_conversations_scheduled] do
      socket
    else
      Process.send_after(self(), :refresh_conversations, delay_ms)
      assign(socket, :refresh_conversations_scheduled, true)
    end
  end

  defp open_conversation(socket, conversation) do
    conversation_id = conversation.id
    active_server_id = conversation_server_id(conversation) || socket.assigns[:active_server_id]

    federation_presence =
      presence_map_for_conversation(conversation, socket.assigns.current_user.id)

    current_unread_counts = socket.assigns.conversation.unread_counts || %{}
    updated_unread_counts = Map.put(current_unread_counts, conversation_id, 0)

    current_member =
      Enum.find(
        conversation.members,
        &(&1.user_id == socket.assigns.current_user.id and is_nil(&1.left_at))
      )

    can_send =
      current_member &&
        Elektrine.Messaging.ConversationMember.can_send_messages?(current_member)

    updated_socket =
      socket
      |> maybe_update_conversation_subscriptions(conversation_id)
      |> assign(:conversation, %{
        socket.assigns.conversation
        | selected: conversation,
          unread_counts: updated_unread_counts,
          filtered:
            refresh_conversation_filter(
              socket.assigns.conversation.list,
              socket.assigns.search.conversation_query,
              socket.assigns.current_user.id,
              active_server_id
            )
      })
      |> assign(:active_server_id, active_server_id)
      |> assign(:federation_presence, federation_presence)
      |> assign(:messages, [])
      |> assign(:message, %{
        socket.assigns.message
        | read_status: %{},
          typing_users: []
      })
      |> assign(:moderation, %{
        socket.assigns.moderation
        | user_timeout_status: %{}
      })
      |> assign(:can_send_messages, can_send)
      |> assign(:first_unread_message_id, nil)
      |> assign(:typing_timer, nil)
      |> assign(:has_more_older_messages, false)
      |> assign(:has_more_newer_messages, false)
      |> assign(:oldest_message_id, nil)
      |> assign(:newest_message_id, nil)
      |> assign(:loading_older_messages, false)
      |> assign(:loading_newer_messages, false)
      |> assign(:initial_messages_loading, true)

    updated_socket =
      if connected?(updated_socket) do
        send(self(), {:load_conversation_messages, conversation_id})
        refresh_room_presence_tracking(updated_socket)
      else
        updated_socket
      end

    updated_socket
  end

  defp maybe_update_conversation_subscriptions(socket, conversation_id) do
    if connected?(socket) do
      previous_conversation_id =
        socket.assigns.conversation.selected && socket.assigns.conversation.selected.id

      if is_integer(previous_conversation_id) and previous_conversation_id != conversation_id do
        Phoenix.PubSub.unsubscribe(Elektrine.PubSub, "conversation:#{previous_conversation_id}")
        Phoenix.PubSub.unsubscribe(Elektrine.PubSub, "chat:#{previous_conversation_id}")
      end

      if previous_conversation_id != conversation_id do
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "conversation:#{conversation_id}")
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "chat:#{conversation_id}")
      end
    end

    socket
  end

  defp messages_with_date_separators(messages) when is_list(messages) do
    {entries, _last_date} =
      Enum.reduce(messages, {[], nil}, fn message, {acc, previous_date} ->
        current_date = message_inserted_date(message)
        show_separator = is_nil(previous_date) or Date.compare(current_date, previous_date) != :eq
        {[{message, show_separator} | acc], current_date}
      end)

    Enum.reverse(entries)
  end

  defp messages_with_date_separators(_), do: []

  defp message_inserted_date(%{inserted_at: %NaiveDateTime{} = inserted_at}),
    do: NaiveDateTime.to_date(inserted_at)

  defp message_inserted_date(%{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_date(inserted_at)

  defp message_inserted_date(_), do: Date.utc_today()

  defp update_conversation_preview(socket, message) do
    conversations = socket.assigns.conversation.list

    {updated_conversations, conversation_found?} =
      Enum.map_reduce(conversations, false, fn conversation, found? ->
        if conversation.id == message.conversation_id do
          last_message_at =
            case message.inserted_at do
              %DateTime{} = datetime -> datetime
              %NaiveDateTime{} = naive_datetime -> DateTime.from_naive!(naive_datetime, "Etc/UTC")
              _ -> conversation.last_message_at
            end

          {%{conversation | messages: [message], last_message_at: last_message_at}, true}
        else
          {conversation, found?}
        end
      end)

    if conversation_found? do
      sorted_conversations =
        Helpers.sort_conversations_by_unread(
          updated_conversations,
          socket.assigns.conversation.unread_counts || %{},
          socket.assigns.current_user.id
        )

      assign(socket, :conversation, %{
        socket.assigns.conversation
        | list: sorted_conversations,
          filtered:
            refresh_conversation_filter(
              sorted_conversations,
              socket.assigns.search.conversation_query,
              socket.assigns.current_user.id,
              socket.assigns[:active_server_id]
            )
      })
    else
      socket
    end
  end

  defp refresh_conversation_filter(conversations, query, current_user_id, active_server_id) do
    scoped_conversations = Helpers.scope_conversations_to_server(conversations, active_server_id)

    case String.trim(query || "") do
      "" ->
        scoped_conversations

      search_query ->
        Helpers.filter_conversations(scoped_conversations, search_query, current_user_id)
    end
  end

  defp get_cached_conversations(user_id) do
    case Elektrine.AppCache.get_conversations(user_id, fn ->
           all_conversations = Messaging.list_conversations(user_id)
           Enum.reject(all_conversations, &(&1.type in ["timeline", "community"]))
         end) do
      {:ok, conversations} ->
        conversations

      {:error, reason} ->
        Logger.warning(
          "failed to fetch cached conversations for user #{user_id}: #{inspect(reason)}"
        )

        all_conversations = Messaging.list_conversations(user_id)
        Enum.reject(all_conversations, &(&1.type in ["timeline", "community"]))
    end
  end

  defp get_cached_unread_count(user_id) do
    case Elektrine.AppCache.get_chat_unread_count(user_id, fn ->
           Messaging.get_unread_count(user_id)
         end) do
      {:ok, unread_count} ->
        unread_count

      {:error, reason} ->
        Logger.warning(
          "failed to fetch cached unread count for user #{user_id}: #{inspect(reason)}"
        )

        Messaging.get_unread_count(user_id)
    end
  end

  defp build_federation_preview do
    config = Application.get_env(:elektrine, :messaging_federation, [])

    %{
      enabled: Keyword.get(config, :enabled, false),
      relay_operator:
        config
        |> Keyword.get(:official_relay_operator, "Community-operated")
        |> normalize_relay_operator_label(),
      official_relays:
        config
        |> Keyword.get(:official_relays, [])
        |> Enum.map(&normalize_official_relay/1)
        |> Enum.reject(&is_nil/1)
    }
  end

  defp normalize_official_relay(relay) when is_binary(relay) do
    case String.trim(relay) do
      "" -> nil
      url -> %{url: url, name: nil}
    end
  end

  defp normalize_official_relay(relay) when is_map(relay) do
    url = relay[:url] || relay["url"]
    name = relay[:name] || relay["name"]

    if is_binary(url) and String.trim(url) != "" do
      normalized_name =
        if is_binary(name) and String.trim(name) != "" do
          String.trim(name)
        else
          nil
        end

      %{url: String.trim(url), name: normalized_name}
    else
      nil
    end
  end

  defp normalize_official_relay(_), do: nil

  defp normalize_relay_operator_label(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" ->
        "Community-operated"

      label ->
        label
    end
  end

  # Delegate helper functions for use in templates
  defdelegate conversation_name(conversation, current_user_id), to: Helpers
  defdelegate format_duration(seconds), to: Helpers
  defdelegate popular_emojis(), to: Helpers
  defdelegate conversation_admin?(conversation, user), to: Helpers
  defdelegate format_reactions(reactions), to: Helpers
  defdelegate user_reacted?(reactions, emoji, user_id), to: Helpers
  defdelegate linkify_urls(text), to: Helpers

  defp route_label(conversation, current_user_id) do
    name = Helpers.conversation_name(conversation, current_user_id) |> to_string()

    case conversation do
      %{type: "channel"} ->
        name
        |> String.trim()
        |> case do
          "" -> "#channel"
          "#" <> _ = prefixed -> prefixed
          trimmed -> "#" <> trimmed
        end

      _ ->
        name
    end
  end

  defp conversation_type_label("group"), do: "Group"
  defp conversation_type_label("channel"), do: "Channel"
  defp conversation_type_label("dm"), do: "Direct Message"

  defp conversation_type_label(type) when is_binary(type),
    do: type |> String.replace("_", " ") |> String.capitalize()

  defp conversation_type_label(_), do: "Chat"

  defp conversation_type_label_lower(type), do: conversation_type_label(type) |> String.downcase()

  defp protocol_conversation_type("dm"), do: "Direct Messages"
  defp protocol_conversation_type("group"), do: "Groups"
  defp protocol_conversation_type("channel"), do: "Channels"

  defp protocol_conversation_type(type) when is_binary(type) do
    type
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp protocol_conversation_type(_), do: "Chats"

  defp remote_conversation?(conversation) when is_map(conversation) do
    Map.get(conversation, :is_federated_mirror, false) ||
      Messaging.remote_dm_conversation?(conversation)
  end

  defp remote_conversation?(_), do: false

  # Helper to get display content for either Message or ChatMessage structs
  # Use __struct__ field matching to avoid cyclic dependency issues at compile time
  defp message_display_content(%{__struct__: Elektrine.Messaging.Message} = msg),
    do: Message.display_content(msg)

  defp message_display_content(%{__struct__: Elektrine.Messaging.ChatMessage} = msg),
    do: ChatMessage.display_content(msg)

  defp message_display_content(message) when is_map(message) do
    content =
      message
      |> map_message_value(:content)
      |> fallback_message_text(message)
      |> normalize_message_text()

    if content != "", do: content, else: fallback_message_label(message)
  end

  defp message_display_content(_), do: ""

  defp fallback_message_text(nil, message), do: map_message_value(message, :body)
  defp fallback_message_text("", message), do: map_message_value(message, :body)
  defp fallback_message_text(content, _message), do: content

  defp fallback_message_label(message) do
    message_type = map_message_value(message, :message_type)
    media_urls = map_message_value(message, :media_urls) || []

    cond do
      message_type == "voice" ->
        "Voice message"

      message_type == "image" ->
        "Photo"

      message_type == "file" ->
        "File"

      message_type == "system" ->
        "[System message]"

      is_list(media_urls) and media_urls != [] ->
        "[Attachment]"

      true ->
        ""
    end
  end

  defp normalize_message_text(nil), do: ""

  defp normalize_message_text(text) when is_binary(text) do
    text
    |> String.trim()
  end

  defp normalize_message_text(text) when is_atom(text), do: Atom.to_string(text)
  defp normalize_message_text(text) when is_integer(text), do: Integer.to_string(text)
  defp normalize_message_text(text) when is_float(text), do: Float.to_string(text)
  defp normalize_message_text(_), do: ""

  defp map_message_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp message_sender(message) when is_map(message) do
    case Map.get(message, :sender) do
      %Ecto.Association.NotLoaded{} ->
        %{}

      sender when is_map(sender) ->
        sender

      _ ->
        %{}
    end
  end

  defp message_sender(_), do: %{}

  defp sender_name(%Ecto.Association.NotLoaded{}), do: HandleFormatter.handle(nil)
  defp sender_name(sender) when is_map(sender), do: HandleFormatter.handle(sender)
  defp sender_name(_), do: HandleFormatter.handle(nil)

  defp message_sender_name(message), do: message |> message_sender() |> sender_name()

  defp message_sender_tag(message), do: "@" <> message_sender_name(message)

  defp user_at_handle(user), do: HandleFormatter.at_handle(user)
  defp user_domain(user), do: HandleFormatter.domain(user)

  defp local_sender_id(message) when is_map(message) do
    case Map.get(message, :sender_id) do
      id when is_integer(id) -> id
      _ -> nil
    end
  end

  defp local_sender_id(_), do: nil

  defp local_sender?(message), do: is_integer(local_sender_id(message))

  defp sender_timeout?(message, timeout_status) when is_map(timeout_status) do
    case local_sender_id(message) do
      id when is_integer(id) -> Map.get(timeout_status, id, false)
      _ -> false
    end
  end

  defp sender_timeout?(_message, _timeout_status), do: false

  defp sender_loaded?(%Ecto.Association.NotLoaded{}), do: false
  defp sender_loaded?(nil), do: false
  defp sender_loaded?(sender) when is_map(sender), do: true
  defp sender_loaded?(_), do: false

  # Load custom emojis that are visible in the picker
  defp load_custom_emojis do
    Elektrine.Emojis.list_picker_emojis()
  end

  defp filter_custom_emojis(emojis, query) when is_binary(query) and query != "" do
    query = String.downcase(query)
    Enum.filter(emojis, fn e -> String.contains?(String.downcase(e.shortcode), query) end)
  end

  defp filter_custom_emojis(emojis, _), do: emojis

  defp selected_server_id(socket) do
    case socket.assigns.conversation.selected do
      %{server_id: server_id} when is_integer(server_id) ->
        server_id

      _ ->
        case socket.assigns[:active_server_id] do
          server_id when is_integer(server_id) -> server_id
          _ -> nil
        end
    end
  end

  defp conversation_server_id(%{server_id: server_id}) when is_integer(server_id), do: server_id
  defp conversation_server_id(_), do: nil

  defp presence_map_for_conversation(%{type: "channel", id: conversation_id}, user_id)
       when is_integer(conversation_id) and is_integer(user_id) do
    conversation_id
    |> Messaging.list_visible_room_presence_states(user_id)
    |> Map.new(fn state -> {state.remote_actor_id, state} end)
  end

  defp presence_map_for_conversation(_, _), do: %{}

  defp remote_presence_online_count(presence_map) when is_map(presence_map) do
    presence_map
    |> Map.values()
    |> Enum.count(fn state ->
      status = state[:status] || state["status"]
      status in ["online", "idle", "dnd"]
    end)
  end

  defp remote_presence_online_count(_), do: 0

  defp refresh_room_presence_tracking(socket) do
    socket = cancel_room_presence_timer(socket)

    case socket.assigns.conversation.selected do
      %{type: "channel", id: conversation_id} when is_integer(conversation_id) ->
        publish_room_presence(conversation_id, socket.assigns.current_user.id, socket)

        timer_ref =
          Process.send_after(self(), :room_presence_heartbeat, @room_presence_heartbeat_ms)

        assign(socket, :room_presence_timer_ref, timer_ref)

      _ ->
        assign(socket, :room_presence_timer_ref, nil)
    end
  end

  defp cancel_room_presence_timer(socket) do
    case socket.assigns[:room_presence_timer_ref] do
      timer_ref when is_reference(timer_ref) ->
        Process.cancel_timer(timer_ref)
        assign(socket, :room_presence_timer_ref, nil)

      _ ->
        assign(socket, :room_presence_timer_ref, nil)
    end
  end

  defp publish_room_presence(conversation_id, user_id, _socket)
       when is_integer(conversation_id) and is_integer(user_id) do
    Elektrine.Messaging.Federation.publish_room_presence_update(
      conversation_id,
      user_id,
      "online",
      []
    )
  end

  defp normalize_optional_text(nil), do: nil

  defp normalize_optional_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_text(_), do: nil

  defp restore_active_call_state(socket, user_id) when is_integer(user_id) do
    case latest_active_call_for_user(user_id) do
      nil ->
        socket

      {:local, %{} = call} ->
        assign(socket, :call, %{
          socket.assigns.call
          | active_call: call,
            incoming_call: nil,
            status: call_status(call),
            audio_enabled: true,
            video_enabled: call.call_type == "video"
        })

      {:federated, %{} = session} ->
        call = VoiceCalls.ui_call(session)

        assign(socket, :call, %{
          socket.assigns.call
          | active_call: call,
            incoming_call: nil,
            status: call_status(call),
            audio_enabled: true,
            video_enabled: call.call_type == "video"
        })
    end
  end

  defp latest_active_call_for_user(user_id) do
    local_call = Calls.get_active_call(user_id)
    federated_call = VoiceCalls.get_active_session_for_local_user(user_id)

    case {local_call, federated_call} do
      {nil, nil} ->
        nil

      {%{} = local, nil} ->
        {:local, local}

      {nil, %{} = federated} ->
        {:federated, federated}

      {%{} = local, %{} = federated} ->
        if DateTime.compare(naive_or_utc(local.updated_at), naive_or_utc(federated.updated_at)) in [:gt, :eq] do
          {:local, local}
        else
          {:federated, federated}
        end
    end
  end

  defp maybe_resume_active_call(socket) do
    case socket.assigns.call.active_call do
      nil ->
        socket

      %{} = call ->
        transport = CallTransport.descriptor_for_user(socket.assigns.current_user.id, call.id)

        push_event(socket, "resume_call", %{
          call_id: call.id,
          call_type: call.call_type,
          ice_servers: transport["ice_servers"],
          transport: transport,
          user_token: socket.assigns.user_token,
          user_id: socket.assigns.current_user.id,
          initiator: call_initiator?(call, socket.assigns.current_user.id)
        })
    end
  end

  defp call_initiator?(%{source: :federated, caller_id: caller_id}, current_user_id)
       when is_integer(caller_id) and is_integer(current_user_id),
       do: caller_id == current_user_id

  defp call_initiator?(%{caller_id: caller_id}, current_user_id)
       when is_integer(caller_id) and is_integer(current_user_id),
       do: caller_id == current_user_id

  defp call_initiator?(_call, _current_user_id), do: false

  defp call_status(%{status: status}) when status in ["initiated", "ringing"], do: "connecting"
  defp call_status(%{status: "active"}), do: "connected"
  defp call_status(%{status: status}) when is_binary(status), do: status
  defp call_status(_call), do: "connecting"

  defp naive_or_utc(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp naive_or_utc(%DateTime{} = value), do: value

  defp parse_checkbox_value(value) when is_list(value) do
    Enum.any?(value, &parse_checkbox_value/1)
  end

  defp parse_checkbox_value(value) do
    value in [true, "true", "on", "1", 1]
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

  defp maybe_add_remote_dm_search_result(results, query)
       when is_list(results) and is_binary(query) do
    case normalize_remote_dm_handle_query(query) do
      {:ok, remote_handle} ->
        already_present? =
          Enum.any?(results, fn user ->
            user_handle = Map.get(user, :handle) || Map.get(user, "handle")
            String.downcase(to_string(user_handle || "")) == remote_handle
          end)

        if already_present? do
          results
        else
          [remote_dm_search_result(remote_handle) | results]
        end

      :error ->
        results
    end
  end

  defp maybe_add_remote_dm_search_result(results, _query), do: results

  defp normalize_remote_dm_handle_query(handle) when is_binary(handle) do
    normalized =
      handle
      |> String.trim()
      |> String.trim_leading("@")
      |> String.downcase()

    case Regex.run(~r/^([a-z0-9_]{1,64})@([a-z0-9.-]+\.[a-z]{2,})$/, normalized) do
      [_, username, domain] -> {:ok, "#{username}@#{domain}"}
      _ -> :error
    end
  end

  defp normalize_remote_dm_handle_query(_), do: :error

  defp remote_dm_search_result(remote_handle) do
    [username, _domain] = String.split(remote_handle, "@", parts: 2)

    %{
      id: nil,
      username: username,
      handle: remote_handle,
      display_name: "@#{remote_handle}",
      avatar: nil,
      remote_handle: remote_handle
    }
  end

  defp social_link_preview_success?(preview) do
    social_link_preview?(preview) and Map.get(preview, :status) == "success"
  end

  defp social_link_preview?(%{__struct__: :"Elixir.Elektrine.Social.LinkPreview"}), do: true
  defp social_link_preview?(_), do: false

  defp extract_email_address(email_string) when is_binary(email_string) do
    case Regex.run(~r/<([^>]+)>/, email_string) do
      [_, email] -> String.trim(email)
      nil -> String.trim(email_string)
    end
  end

  defp extract_email_address(_email_string), do: "Unknown"

  defp get_emojis_for_category("Smileys"),
    do:
      ~w(😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 ☺️ 😚 😙 🥲 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🤫 🤔 🤐 🤨 😐 😑 😶 😏 😒 🙄 😬 🤥 😌 😔 😪 🤤 😴 😷)

  defp get_emojis_for_category("Gestures"),
    do: ~w(👋 🤚 🖐️ ✋ 🖖 👌 🤌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 🖕 👇 ☝️ 👍 👎 ✊ 👊 🤛 🤜 👏 🙌 👐 🤲 🤝 🙏 ✍️ 💪)

  defp get_emojis_for_category("Hearts"), do: ~w(❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💟 ♥️)

  defp get_emojis_for_category("Animals"),
    do: ~w(🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐒 🐔 🐧 🐦 🐤 🐣 🐥 🦆 🦅 🦉 🦇 🐺 🐗 🐴 🦄 🐝)

  defp get_emojis_for_category("Food"),
    do: ~w(🍏 🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🫐 🍈 🍒 🍑 🥭 🍍 🥥 🥝 🍅 🍆 🥑 🥦 🥬 🥒 🌽 🥕 🥔 🍠 🥐 🥖 🍞 🥨 🍳 🥚 🧀)

  defp get_emojis_for_category(_), do: Helpers.popular_emojis()
end
