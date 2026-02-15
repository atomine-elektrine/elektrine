defmodule ElektrineWeb.ChatLive.Index do
  use ElektrineWeb, :live_view

  alias Elektrine.Messaging
  alias Elektrine.Messaging.Message
  alias Elektrine.Messaging.ChatMessage
  alias Elektrine.Accounts.User
  alias Elektrine.Constants
  import ElektrineWeb.Components.User.Avatar
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.Components.Social.ContentJourney
  import ElektrineWeb.Components.Chat.Call
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.Social.EmbeddedPost
  import ElektrineWeb.Live.NotificationHelpers
  import ElektrineWeb.HtmlHelpers, only: [ensure_https: 1]

  # Import operation modules
  alias ElektrineWeb.ChatLive.Operations.Helpers
  alias ElektrineWeb.ChatLive.State

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
    {:ok, cached_conversations} =
      Elektrine.AppCache.get_conversations(user.id, fn ->
        all_conversations = Messaging.list_conversations(user.id)
        Enum.reject(all_conversations, &(&1.type in ["timeline", "community"]))
      end)

    {:ok, cached_unread} =
      Elektrine.AppCache.get_chat_unread_count(user.id, fn ->
        Messaging.get_unread_count(user.id)
      end)

    # Initialize with cached data to prevent flicker
    socket =
      socket
      |> assign(:page_title, "Chat")
      |> assign(:ui, %State.UI{})
      |> assign(:search, %State.Search{user_results: []})
      |> assign(:call, %State.Call{})
      |> assign(:form, %State.Form{})
      |> assign(:context_menu, %State.ContextMenu{})
      |> assign(:message, %State.Message{})
      |> assign(:conversation, %State.Conversation{
        list: cached_conversations,
        selected: nil,
        filtered: cached_conversations,
        last_message_read_status: %{},
        unread_count: cached_unread,
        unread_counts: %{}
      })
      |> assign(:moderation, %State.Moderation{})
      |> assign(:browse, %State.Browse{})
      |> assign(:profile, %State.Profile{})
      |> assign(:messages, [])
      |> assign(:uploaded_files, [])
      |> assign(:can_send_messages, true)
      |> allow_upload(:chat_attachments,
        accept: ~w(.jpg .jpeg .png .gif .webp .pdf .doc .docx .xls .xlsx .txt),
        max_entries: 5,
        max_file_size: chat_attachment_limit
      )
      |> assign(:user_token, Helpers.generate_user_token(user.id))
      |> assign(:show_mobile_search, false)
      |> assign(:show_report_modal, false)
      |> assign(:report_type, nil)
      |> assign(:report_id, nil)
      |> assign(:report_metadata, %{})
      |> assign(:user_communities, [])
      |> assign(:has_more_older_messages, false)
      |> assign(:has_more_newer_messages, false)
      |> assign(:oldest_message_id, nil)
      |> assign(:processed_call_events, MapSet.new())
      |> assign(:newest_message_id, nil)
      |> assign(:loading_older_messages, false)
      |> assign(:loading_newer_messages, false)
      |> assign(:first_unread_message_id, nil)
      |> assign(:show_image_modal, false)
      |> assign(:modal_image_url, nil)
      |> assign(:modal_images, [])
      |> assign(:modal_image_index, 0)
      |> assign(:modal_post, nil)
      |> assign(:public_group_search_results, [])
      |> assign(:public_channel_search_results, [])
      |> assign(:custom_emojis, load_custom_emojis())
      |> assign(
        :loading_conversations,
        !Enum.empty?(cached_conversations) || Messaging.user_has_conversations?(user.id)
      )

    # Load conversations async after connection
    if connected?(socket) do
      send(self(), :load_conversations)
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
        {:ok, _} ->
          # Successfully joined, trigger conversation refresh and redirect
          Process.send_after(self(), :refresh_conversations, 100)

          {:noreply,
           socket
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
           |> notify_error("This is a private conversation - you need an invitation to join")
           |> push_navigate(to: ~p"/chat")}

        {:error, _} ->
          {:noreply,
           socket
           |> notify_error("Unable to join conversation")
           |> push_navigate(to: ~p"/chat")}
      end
    else
      # Invalid conversation identifier
      {:noreply,
       socket
       |> notify_error("Invalid conversation link")
       |> push_navigate(to: ~p"/chat")}
    end
  end

  def handle_params(%{"conversation_id" => conversation_identifier}, _url, socket) do
    # Try to find by hash first, then by ID for backwards compatibility
    conversation_id =
      case Messaging.get_conversation_by_hash(conversation_identifier) do
        %{id: id} ->
          id

        nil ->
          case Integer.parse(conversation_identifier) do
            {id, ""} -> id
            _ -> nil
          end
      end

    if conversation_id do
      # Use lightweight loader - messages are loaded separately
      case Messaging.get_conversation_for_chat!(conversation_id, socket.assigns.current_user.id) do
        {:ok, conversation} ->
          # If accessed by ID instead of hash, redirect to hash URL
          if conversation_identifier != conversation.hash && conversation.hash do
            {:noreply,
             socket
             |> push_navigate(to: ~p"/chat/#{conversation.hash}")}
          else
            # Unsubscribe from previous conversation and subscribe to new one
            if connected?(socket) do
              # Unsubscribe from previous conversation if there was one
              if socket.assigns.conversation.selected do
                Phoenix.PubSub.unsubscribe(
                  Elektrine.PubSub,
                  "conversation:#{socket.assigns.conversation.selected.id}"
                )

                Phoenix.PubSub.unsubscribe(
                  Elektrine.PubSub,
                  "chat:#{socket.assigns.conversation.selected.id}"
                )
              end

              # Subscribe to new conversation (both legacy and chat topics)
              Phoenix.PubSub.subscribe(Elektrine.PubSub, "conversation:#{conversation_id}")
              Phoenix.PubSub.subscribe(Elektrine.PubSub, "chat:#{conversation_id}")
            end

            # Load initial messages using pagination
            # Use Messages module for all conversation types (messages table)
            data =
              Messaging.get_conversation_messages(conversation_id, socket.assigns.current_user.id,
                limit: 50
              )

            messages =
              data.messages
              |> Enum.reverse()
              |> Elektrine.Messaging.Message.decrypt_messages()

            message_data = data

            # Find first unread message for scroll positioning
            first_unread_message_id =
              Helpers.find_first_unread_message(
                messages,
                conversation_id,
                socket.assigns.current_user.id
              )

            # Mark conversation as read immediately (after brief delay for UI to settle)
            # This ensures notifications created in the next 200ms get cleaned up quickly
            Process.send_after(self(), {:mark_conversation_read, conversation_id}, 200)

            # Defer read status loading for faster initial render
            # Read receipts are nice-to-have, not critical for initial display
            message_ids = Enum.map(messages, & &1.id)

            if message_ids != [] do
              Process.send_after(self(), {:load_read_status, message_ids, conversation_id}, 150)
            end

            # Load timeout status for all users in conversation (single batched query)
            user_ids = conversation.members |> Enum.map(& &1.user_id) |> Enum.uniq()
            timeout_status = Helpers.load_timeout_status(user_ids, conversation_id)

            # Calculate current unread counts, but mark this conversation as 0 in UI
            current_unread_counts =
              socket.assigns.conversation.unread_counts ||
                Helpers.calculate_unread_counts(
                  socket.assigns.conversation.list,
                  socket.assigns.current_user.id
                )

            # Immediately update UI to show this conversation as read (even though we delay the DB update)
            updated_unread_counts = Map.put(current_unread_counts, conversation.id, 0)

            # Check if current user can send messages in this conversation
            current_member =
              Enum.find(
                conversation.members,
                &(&1.user_id == socket.assigns.current_user.id and is_nil(&1.left_at))
              )

            can_send =
              current_member &&
                Elektrine.Messaging.ConversationMember.can_send_messages?(current_member)

            # Build socket with updated assigns
            # Start with empty read_status - it will be loaded async
            updated_socket =
              socket
              |> assign(:conversation, %{
                socket.assigns.conversation
                | selected: conversation,
                  unread_counts: updated_unread_counts
              })
              |> assign(:messages, messages)
              |> assign(:message, %{
                socket.assigns.message
                | read_status: %{},
                  typing_users: []
              })
              |> assign(:moderation, %{
                socket.assigns.moderation
                | user_timeout_status: timeout_status
              })
              |> assign(:can_send_messages, can_send)
              |> assign(:first_unread_message_id, first_unread_message_id)
              |> assign(:typing_timer, nil)
              |> assign(:has_more_older_messages, message_data.has_more_older)
              |> assign(:has_more_newer_messages, message_data.has_more_newer)
              |> assign(:oldest_message_id, message_data.oldest_id)
              |> assign(:newest_message_id, message_data.newest_id)
              |> assign(:loading_older_messages, false)
              |> assign(:loading_newer_messages, false)

            # Trigger initial scroll based on unread status
            Process.send_after(self(), :trigger_initial_scroll, 100)

            {:noreply, updated_socket}
          end

        {:error, :not_found} ->
          {:noreply,
           socket
           |> notify_error("Conversation not found")
           |> push_navigate(to: ~p"/chat")}
      end
    else
      # Invalid conversation identifier
      {:noreply,
       socket
       |> notify_error("Invalid conversation")
       |> push_navigate(to: ~p"/chat")}
    end
  end

  def handle_params(_params, _url, socket) do
    # Clear selected conversation when navigating to /chat without a conversation_id
    {:noreply, assign(socket, :conversation, %{socket.assigns.conversation | selected: nil})}
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

    {:noreply,
     socket
     |> assign(:conversation, %{
       socket.assigns.conversation
       | list: conversations,
         filtered: conversations,
         last_message_read_status: last_message_read_status,
         unread_count: unread_count,
         unread_counts: unread_counts
     })
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
      results = Messaging.search_users(query, socket.assigns.current_user.id)
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

  def handle_info({:start_dm, user_id_str}, socket) do
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
    updated_ui =
      socket.assigns.ui
      |> Map.put(:show_channel_modal, true)
      |> Map.put(:show_group_modal, false)
      |> Map.put(:show_new_chat, false)

    {:noreply,
     socket
     |> assign(:ui, updated_ui)}
  end

  def handle_info({:show_browse_modal}, socket) do
    public_channels = Messaging.list_public_channels()
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
       | tab: "channels",
         public_channels: public_channels,
         public_groups: public_groups,
         filtered_channels: public_channels,
         filtered_groups: public_groups
     })}
  end

  def handle_info({:close_group_modal}, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_group_modal, false))}
  end

  def handle_info({:close_channel_modal}, socket) do
    {:noreply, assign(socket, :ui, Map.put(socket.assigns.ui, :show_channel_modal, false))}
  end

  def handle_info({:create_group, group_params, selected_users}, socket) do
    name = Map.get(group_params, "name", "")
    description = Map.get(group_params, "description", "")
    is_public = Map.get(group_params, "is_public") == "true"

    if String.trim(name) != "" and selected_users != [] do
      member_ids = Enum.map(selected_users, & &1.id)

      case Messaging.create_group_conversation(
             socket.assigns.current_user.id,
             %{
               name: String.trim(name),
               description: String.trim(description),
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
    else
      {:noreply,
       socket
       |> notify_error("Please provide a group name and select at least one member.")}
    end
  end

  def handle_info({:create_channel, channel_params}, socket) do
    name = Map.get(channel_params, "name", "")
    description = Map.get(channel_params, "description", "")
    is_public = Map.get(channel_params, "is_public") == "true"

    if String.trim(name) != "" do
      case Messaging.create_channel(
             socket.assigns.current_user.id,
             %{
               name: String.trim(name),
               description: String.trim(description),
               is_public: is_public
             }
           ) do
        {:ok, conversation} ->
          {:noreply,
           socket
           |> assign(:ui, Map.put(socket.assigns.ui, :show_channel_modal, false))
           |> notify_info("Channel created successfully!")
           |> push_navigate(to: ~p"/chat/#{conversation.hash || conversation.id}")}

        {:error, :channel_limit_exceeded} ->
          {:noreply,
           socket
           |> notify_error("You've reached the maximum limit of 10 channels")}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> notify_error("Failed to create channel. Please try again.")}
      end
    else
      {:noreply,
       socket
       |> notify_error("Please provide a channel name.")}
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

    case Messaging.add_reaction(message_id, socket.assigns.current_user.id, emoji) do
      {:ok, _reaction} -> {:noreply, socket}
      {:error, _} -> {:noreply, socket}
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
    Process.send_after(self(), :refresh_conversations, 50)

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
    # Refresh conversations list to show the new conversation
    all_conversations = Messaging.list_conversations(socket.assigns.current_user.id)
    conversations = Enum.reject(all_conversations, &(&1.type in ["timeline", "community"]))

    {:noreply,
     socket
     |> assign(:conversations, conversations)
     |> assign(:filtered_conversations, conversations)}
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

    # Re-filter conversations if search is active
    filtered_conversations =
      if socket.assigns.search.conversation_query != "" do
        Helpers.filter_conversations(
          conversations,
          socket.assigns.search.conversation_query,
          socket.assigns.current_user.id
        )
      else
        conversations
      end

    {:noreply,
     socket
     |> assign(:conversation, %{
       socket.assigns.conversation
       | list: conversations,
         filtered: filtered_conversations,
         unread_count: unread_count,
         unread_counts: unread_counts,
         last_message_read_status: last_message_read_status
     })}
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

  def handle_info({:new_message_notification, _message}, socket) do
    # This handles messages from other conversations (for notifications and conversation list updates)
    # Immediately update conversation list and unread counts
    all_conversations = Messaging.list_conversations(socket.assigns.current_user.id)

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

    # Re-filter conversations if search is active
    filtered_conversations =
      if socket.assigns.search.conversation_query != "" do
        Helpers.filter_conversations(
          conversations,
          socket.assigns.search.conversation_query,
          socket.assigns.current_user.id
        )
      else
        conversations
      end

    socket =
      socket
      |> assign(:conversation, %{
        socket.assigns.conversation
        | list: conversations,
          filtered: filtered_conversations,
          unread_count: unread_count,
          unread_counts: unread_counts,
          last_message_read_status: last_message_read_status
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_email, message}, socket) do
    # Handle email notifications while in chat
    socket =
      push_event(socket, "new_email", %{
        from: Elektrine.Email.extract_email_address(message.from || "Unknown"),
        subject: String.slice(message.subject || "No Subject", 0, 100)
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_message, message}, socket) do
    # Always refresh conversation list to update message previews and unread counts
    Process.send_after(self(), :refresh_conversations, 100)

    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == message.conversation_id do
      # Decrypt the new message before adding it
      decrypted_message = Elektrine.Messaging.Message.decrypt_content(message)
      messages = socket.assigns.messages ++ [decrypted_message]

      # Update read status for the new message
      current_read_status = socket.assigns.message.read_status
      updated_read_status = Map.put(current_read_status, message.id, [])

      # Update newest message ID for pagination
      newest_id = message.id

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

      # Scroll to bottom after adding the message
      # Always scroll if it's your own message, ensures media messages are visible
      updated_socket =
        socket
        |> assign(:messages, messages)
        |> assign(:message_read_status, updated_read_status)
        |> assign(:newest_message_id, newest_id)
        |> assign(:has_more_newer_messages, false)

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
    else
      {:noreply, socket}
    end
  end

  def handle_info({:message_edited, message}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == message.conversation_id do
      # Decrypt the edited message
      decrypted_message = Elektrine.Messaging.Message.decrypt_content(message)

      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == message.id, do: decrypted_message, else: msg
        end)

      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:message_deleted, message}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == message.conversation_id do
      # Remove deleted message from the list entirely
      messages = Enum.reject(socket.assigns.messages, fn msg -> msg.id == message.id end)

      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  # Chat message handlers (from ChatMessages module for DMs/groups/channels)
  def handle_info({:new_chat_message, message}, socket) do
    # Refresh conversation list to update message previews and unread counts
    Process.send_after(self(), :refresh_conversations, 100)

    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == message.conversation_id do
      # ChatMessage is already decrypted from the broadcast
      messages = socket.assigns.messages ++ [message]

      # Update read status for the new message
      current_read_status = socket.assigns.message.read_status
      updated_read_status = Map.put(current_read_status, message.id, [])

      # If this is not my message, mark it as read immediately
      if message.sender_id != socket.assigns.current_user.id do
        user_id = socket.assigns.current_user.id
        Messaging.mark_chat_messages_read(message.conversation_id, user_id, message.id)
      end

      updated_socket =
        socket
        |> assign(:messages, messages)
        |> assign(:message, %{socket.assigns.message | read_status: updated_read_status})

      # Scroll to bottom
      {:noreply, push_event(updated_socket, "scroll_to_bottom", %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:chat_message_updated, message}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == message.conversation_id do
      # Message is already decrypted from the broadcast
      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == message.id, do: message, else: msg
        end)

      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:chat_message_deleted, message_id}, socket) do
    # Remove deleted message from the list
    messages = Enum.reject(socket.assigns.messages, fn msg -> msg.id == message_id end)
    {:noreply, assign(socket, :messages, messages)}
  end

  def handle_info({:message_pinned, message}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == message.conversation_id do
      # Update the message's is_pinned status in the list
      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == message.id do
            %{
              msg
              | is_pinned: true,
                pinned_at: message.pinned_at,
                pinned_by_id: message.pinned_by_id
            }
          else
            msg
          end
        end)

      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:message_unpinned, message}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == message.conversation_id do
      # Update the message's is_pinned status in the list
      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == message.id do
            %{msg | is_pinned: false, pinned_at: nil, pinned_by_id: nil}
          else
            msg
          end
        end)

      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:reaction_added, reaction}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == reaction.message.conversation_id do
      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == reaction.message.id do
            # Check if this reaction already exists to prevent duplicates
            existing_reaction =
              Enum.find(msg.reactions, fn r ->
                r.user_id == reaction.user_id and r.emoji == reaction.emoji
              end)

            if existing_reaction do
              # Reaction already exists, don't add duplicate
              msg
            else
              # Add new reaction
              %{msg | reactions: msg.reactions ++ [reaction]}
            end
          else
            msg
          end
        end)

      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:reaction_removed, reaction}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == reaction.message.conversation_id do
      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == reaction.message.id do
            reactions = Enum.reject(msg.reactions, &(&1.id == reaction.id))
            %{msg | reactions: reactions}
          else
            msg
          end
        end)

      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:message_link_preview_updated, updated_message}, socket) do
    if socket.assigns.conversation.selected &&
         socket.assigns.conversation.selected.id == updated_message.conversation_id do
      messages =
        Enum.map(socket.assigns.messages, fn msg ->
          if msg.id == updated_message.id do
            %{msg | link_preview: updated_message.link_preview}
          else
            msg
          end
        end)

      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:notification_count_updated, new_count}, socket) do
    {:noreply, assign(socket, :notification_count, new_count)}
  end

  # Call-related PubSub messages
  def handle_info({:incoming_call, call}, socket) do
    # Deduplicate - ignore if already showing this call
    if socket.assigns.call && socket.assigns.call.incoming_call &&
         socket.assigns.call.incoming_call.id == call.id do
      {:noreply, socket}
    else
      # Reload call with user data if not already loaded
      call =
        if Ecto.assoc_loaded?(call.caller) do
          call
        else
          Elektrine.Calls.get_call_with_users(call.id)
        end

      socket =
        socket
        |> assign(:call, %{socket.assigns.call | incoming_call: call, status: "ringing"})
        |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, true))
        |> push_event("play_incoming_ringtone", %{})

      {:noreply, socket}
    end
  end

  def handle_info({:call_rejected, call}, socket) do
    # Deduplication key
    event_key = {"call_rejected", call.id}

    # Check if we already processed this event
    if MapSet.member?(socket.assigns.processed_call_events, event_key) do
      {:noreply, socket}
    else
      # Only process if this LiveView has the call (not just subscribed)
      has_incoming =
        socket.assigns.call && socket.assigns.call.incoming_call &&
          socket.assigns.call.incoming_call.id == call.id

      has_active =
        socket.assigns.call && socket.assigns.call.active_call &&
          socket.assigns.call.active_call.id == call.id

      # Mark as processed
      processed = MapSet.put(socket.assigns.processed_call_events, event_key)

      if has_incoming || has_active do
        cleared_call_state =
          socket.assigns.call
          |> Map.put(:incoming_call, nil)
          |> Map.put(:active_call, nil)
          |> Map.put(:status, nil)
          |> Map.put(:audio_enabled, true)
          |> Map.put(:video_enabled, true)

        socket =
          socket
          |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
          |> assign(:call, cleared_call_state)
          |> assign(:processed_call_events, processed)
          |> push_event("stop_ringtone", %{})
          |> notify_info("Call was rejected")

        {:noreply, socket}
      else
        {:noreply, assign(socket, :processed_call_events, processed)}
      end
    end
  end

  def handle_info({:call_ended, call}, socket) do
    # Deduplication key
    event_key = {"call_ended", call.id}

    # Check if we already processed this event
    if MapSet.member?(socket.assigns.processed_call_events, event_key) do
      {:noreply, socket}
    else
      # Only process if this LiveView has the call (not just subscribed)
      has_incoming =
        socket.assigns.call && socket.assigns.call.incoming_call &&
          socket.assigns.call.incoming_call.id == call.id

      has_active =
        socket.assigns.call && socket.assigns.call.active_call &&
          socket.assigns.call.active_call.id == call.id

      # Mark as processed
      processed = MapSet.put(socket.assigns.processed_call_events, event_key)

      if has_incoming || has_active do
        cleared_call_state =
          socket.assigns.call
          |> Map.put(:incoming_call, nil)
          |> Map.put(:active_call, nil)
          |> Map.put(:status, nil)
          |> Map.put(:audio_enabled, true)
          |> Map.put(:video_enabled, true)

        socket =
          socket
          |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
          |> assign(:call, cleared_call_state)
          |> assign(:processed_call_events, processed)
          |> push_event("stop_ringtone", %{})
          |> notify_info("Call ended")

        {:noreply, socket}
      else
        {:noreply, assign(socket, :processed_call_events, processed)}
      end
    end
  end

  def handle_info({:call_missed, call}, socket) do
    # Deduplication key
    event_key = {"call_missed", call.id}

    # Check if we already processed this event
    if MapSet.member?(socket.assigns.processed_call_events, event_key) do
      {:noreply, socket}
    else
      # Only process if this LiveView has the call (not just subscribed)
      has_incoming =
        socket.assigns.call && socket.assigns.call.incoming_call &&
          socket.assigns.call.incoming_call.id == call.id

      has_active =
        socket.assigns.call && socket.assigns.call.active_call &&
          socket.assigns.call.active_call.id == call.id

      # Mark as processed
      processed = MapSet.put(socket.assigns.processed_call_events, event_key)

      if has_incoming || has_active do
        cleared_call_state =
          socket.assigns.call
          |> Map.put(:incoming_call, nil)
          |> Map.put(:active_call, nil)
          |> Map.put(:status, nil)
          |> Map.put(:audio_enabled, true)
          |> Map.put(:video_enabled, true)

        socket =
          socket
          |> assign(:ui, Map.put(socket.assigns.ui, :show_incoming_call, false))
          |> assign(:call, cleared_call_state)
          |> assign(:processed_call_events, processed)
          |> push_event("stop_ringtone", %{})
          |> notify_info("Call timed out")

        {:noreply, socket}
      else
        {:noreply, assign(socket, :processed_call_events, processed)}
      end
    end
  end

  def handle_info(_info, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # Clean up any active calls when user disconnects
    if socket.assigns.call && socket.assigns.call.active_call do
      Elektrine.Calls.end_call(socket.assigns.call.active_call.id)
    end

    # Also force cleanup any hanging calls for this user
    if socket.assigns[:current_user] do
      Elektrine.Jobs.StaleCallCleanup.cleanup_user_calls(socket.assigns.current_user.id)
    end

    :ok
  end

  # Delegate helper functions for use in templates
  defdelegate conversation_name(conversation, current_user_id), to: Helpers
  defdelegate format_duration(seconds), to: Helpers
  defdelegate popular_emojis(), to: Helpers
  defdelegate conversation_admin?(conversation, user), to: Helpers
  defdelegate format_reactions(reactions), to: Helpers
  defdelegate user_reacted?(reactions, emoji, user_id), to: Helpers
  defdelegate linkify_urls(text), to: Helpers

  # Helper to get display content for either Message or ChatMessage structs
  # Use __struct__ field matching to avoid cyclic dependency issues at compile time
  defp message_display_content(%{__struct__: Elektrine.Messaging.Message} = msg),
    do: Message.display_content(msg)

  defp message_display_content(%{__struct__: Elektrine.Messaging.ChatMessage} = msg),
    do: ChatMessage.display_content(msg)

  defp message_display_content(_), do: ""

  # Load custom emojis that are visible in the picker
  defp load_custom_emojis do
    Elektrine.Emojis.list_picker_emojis()
  end

  defp filter_custom_emojis(emojis, query) when is_binary(query) and query != "" do
    query = String.downcase(query)
    Enum.filter(emojis, fn e -> String.contains?(String.downcase(e.shortcode), query) end)
  end

  defp filter_custom_emojis(emojis, _), do: emojis

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
