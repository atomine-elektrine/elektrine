defmodule ElektrineWeb.EmailLive.Index do
  use ElektrineWeb, :live_view
  import ElektrineWeb.EmailLive.EmailHelpers
  import ElektrineWeb.Components.Platform.ElektrineNav
  import ElektrineWeb.CalendarLive.Operations.CalendarOperations, only: [handle_calendar_event: 3]

  alias Elektrine.Calendar, as: Cal
  alias Elektrine.Calendar.Calendar, as: CalendarSchema
  alias Elektrine.Calendar.Event
  alias Elektrine.Email
  alias Elektrine.Email.Cached
  alias Elektrine.Email.RateLimiter
  alias ElektrineWeb.EmailLive.Router

  require Logger

  @calendar_events [
    "prev_month",
    "next_month",
    "today",
    "toggle_calendar",
    "select_date",
    "close_date_detail",
    "new_event",
    "edit_event",
    "view_event",
    "close_event_detail",
    "cancel_event_modal",
    "validate_event",
    "save_event",
    "delete_event",
    "new_calendar",
    "edit_calendar",
    "cancel_calendar_modal",
    "validate_calendar",
    "save_calendar",
    "delete_calendar"
  ]

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns.current_user

    # Mailbox is required for the page to function - must be loaded synchronously
    mailbox = get_or_create_mailbox(user)

    # Set locale from session
    locale = user.locale || session["locale"] || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    # Load cached storage info to prevent the storage bar flicker
    {:ok, cached_storage} =
      Elektrine.AppCache.get_storage_info(user.id, fn ->
        Elektrine.Accounts.Storage.get_storage_info(user.id)
      end)

    # For counts, use fresh DB data to avoid showing stale cached values
    # The slight delay is better than showing wrong numbers (e.g. 75 -> 12)
    fresh_counts = Email.get_all_unread_counts(mailbox.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}")
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "mailbox:#{mailbox.id}")

      # Load sidebar data asynchronously after connection (for non-cached data like labels, folders)
      send(self(), :load_sidebar_data)
    end

    {:ok,
     socket
     |> assign(:page_title, "Email")
     |> assign(:mailbox, mailbox)
     |> assign(:loading_sidebar, true)
     |> assign(:storage_info, cached_storage)
     |> assign(:unread_count, fresh_counts.inbox)
     |> assign(:inbox_unread_count, fresh_counts.inbox)
     |> assign(:digest_count, fresh_counts.feed)
     |> assign(:ledger_count, fresh_counts.ledger)
     |> assign(:stack_unread_count, fresh_counts.stack)
     |> assign(:boomerang_unread_count, fresh_counts.reply_later)
     # default tab
     |> assign(:current_tab, "inbox")
     |> assign(:messages, [])
     |> assign(:selected_messages, [])
     |> assign(:select_all, false)
     |> assign(:current_filter, "all")
     |> assign(:rate_limit_status, %{limited: false})
     |> assign(:search_query, "")
     |> assign(:search_results, [])
     |> assign(:searching, false)
     |> assign(:show_reply_later_modal, false)
     |> assign(:reply_later_message, nil)
     |> assign(:user_labels, [])
     |> assign(:custom_folders, [])
     |> assign(:pagination, %{
       page: 1,
       per_page: 20,
       total_count: 0,
       total_pages: 0,
       has_next: false,
       has_prev: false
     })
     |> assign(:editing_alias, nil)
     |> assign(:edit_alias_form, nil)
     |> assign(:loading_calendar, false)
     |> assign(:calendars, [])
     |> assign(:default_calendar, nil)
     |> assign(:events, [])
     |> assign(:current_date, Date.utc_today())
     |> assign(:view_date, Date.utc_today())
     |> assign(:view_mode, :month)
     |> assign(:selected_date, nil)
     |> assign(:selected_event, nil)
     |> assign(:show_event_modal, false)
     |> assign(:show_calendar_modal, false)
     |> assign(:editing_event, nil)
     |> assign(:editing_calendar, nil)
     |> assign(:event_changeset, Event.changeset(%Event{}, %{}))
     |> assign(:calendar_changeset, CalendarSchema.changeset(%CalendarSchema{}, %{}))
     |> assign(:visible_calendars, MapSet.new())}
  end

  @impl true
  def handle_params(%{"tab" => tab} = params, _url, socket) do
    valid_tabs = [
      "inbox",
      "sent",
      "drafts",
      "spam",
      "trash",
      "archive",
      "search",
      "stack",
      "digest",
      "ledger",
      "boomerang",
      "contacts",
      "folder",
      "calendar"
    ]

    current_tab = if tab in valid_tabs, do: tab, else: "inbox"
    page = SafeConvert.parse_page(params)

    socket =
      socket
      |> assign(:current_tab, current_tab)
      |> assign(:page_title, get_page_title(current_tab))

    # Load content based on tab with pagination
    socket = load_tab_content(socket, current_tab, params, page)

    # Scroll to top when changing tabs
    {:noreply, push_event(socket, "scroll-to-top", %{})}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    if socket.assigns.live_action == :calendar do
      socket =
        socket
        |> assign(:current_tab, "calendar")
        |> assign(:page_title, get_page_title("calendar"))

      {:noreply, load_tab_content(socket, "calendar", %{}, 1)}
    else
      # Default to inbox tab
      socket =
        socket
        |> assign(:current_tab, "inbox")
        |> assign(:page_title, "Inbox")

      socket = load_tab_content(socket, "inbox", %{}, 1)

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(event_name, params, socket) do
    if socket.assigns.current_tab == "calendar" and event_name in @calendar_events do
      handle_calendar_event(event_name, params, socket)
    else
      Router.route_event(event_name, params, socket)
    end
  end

  @impl true
  def handle_info({:unread_count_updated, _new_count}, socket) do
    # Ignore the broadcast count and calculate consistently from cached counts
    mailbox_id = socket.assigns.mailbox.id
    counts = Cached.get_all_unread_counts(mailbox_id)

    {:noreply,
     socket
     |> assign(:unread_count, counts.inbox)
     |> assign(:inbox_unread_count, counts.inbox)
     |> assign(:digest_count, counts.feed)
     |> assign(:ledger_count, counts.ledger)
     |> assign(:stack_unread_count, counts.stack)
     |> assign(:boomerang_unread_count, counts.reply_later)}
  end

  @impl true
  def handle_info(:load_sidebar_data, socket) do
    user = socket.assigns.current_user
    mailbox = socket.assigns.mailbox

    # Load sidebar data in parallel - use FRESH data from DB, not cache
    # This ensures we show accurate counts after initial cached values
    rate_limit_task = Task.async(fn -> RateLimiter.get_rate_limit_status(user.id) end)
    storage_task = Task.async(fn -> Elektrine.Accounts.Storage.get_storage_info(user.id) end)
    labels_task = Task.async(fn -> Email.list_labels(user.id) end)
    folders_task = Task.async(fn -> Email.list_custom_folders(user.id) end)
    # Fetch fresh unread counts from DB (not cache) to ensure accuracy
    all_counts_task = Task.async(fn -> Email.get_all_unread_counts(mailbox.id) end)

    rate_limit_status = Task.await(rate_limit_task)
    storage_info = Task.await(storage_task)
    user_labels = Task.await(labels_task)
    custom_folders = Task.await(folders_task)
    fresh_counts = Task.await(all_counts_task)

    inbox_unread_count = fresh_counts.inbox
    digest_count = fresh_counts.feed
    ledger_count = fresh_counts.ledger
    stack_unread_count = fresh_counts.stack
    boomerang_unread_count = fresh_counts.reply_later

    unread_count = inbox_unread_count

    # Calculate storage in background if needed
    if storage_info && storage_info.used_bytes == 0 do
      Task.start(fn -> Elektrine.Accounts.Storage.update_user_storage(user.id) end)
    end

    {:noreply,
     socket
     |> assign(:loading_sidebar, false)
     |> assign(:unread_count, unread_count)
     |> assign(:rate_limit_status, rate_limit_status)
     |> assign(:storage_info, storage_info)
     |> assign(:user_labels, user_labels)
     |> assign(:custom_folders, custom_folders)
     |> assign(:inbox_unread_count, inbox_unread_count)
     |> assign(:digest_count, digest_count)
     |> assign(:ledger_count, ledger_count)
     |> assign(:stack_unread_count, stack_unread_count)
     |> assign(:boomerang_unread_count, boomerang_unread_count)}
  end

  @impl true
  def handle_info(
        {:storage_updated, %{storage_used_bytes: _used_bytes, user_id: user_id}},
        socket
      ) do
    # Refresh storage info when storage is updated
    if socket.assigns.current_user.id == user_id do
      storage_info = Elektrine.Accounts.Storage.get_storage_info(user_id)
      {:noreply, assign(socket, :storage_info, storage_info)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:added_to_conversation, %{conversation_id: _conversation_id}}, socket) do
    # Handle being added to a conversation - just ignore in email view
    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_dm, message}, socket) do
    # Handle DM notifications while in email
    socket =
      push_event(socket, "new_chat_message", %{
        from: message.sender.username,
        message: String.slice(message.content || "", 0, 100)
      })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:new_email, message}, socket) do
    # Update unread count and refresh current tab to show new message
    mailbox = socket.assigns.mailbox
    unread_count = Email.unread_count(mailbox.id)

    socket =
      assign(socket, :unread_count, unread_count)
      |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox.id))
      |> assign(:digest_count, Cached.unread_feed_count(mailbox.id))
      |> assign(:ledger_count, Cached.unread_ledger_count(mailbox.id))
      |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox.id))
      |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox.id))

    # Refresh current tab if the new message belongs in it
    socket =
      cond do
        # Always refresh inbox for received messages
        socket.assigns.current_tab == "inbox" && message.status != "sent" ->
          load_tab_content(socket, "inbox", %{})

        # Refresh sent folder for sent messages (SMTP/IMAP APPEND)
        socket.assigns.current_tab == "sent" && message.status == "sent" ->
          load_tab_content(socket, "sent", %{})

        # Refresh drafts folder for draft messages
        socket.assigns.current_tab == "drafts" && message.status == "draft" ->
          load_tab_content(socket, "drafts", %{})

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info({:message_flags_updated, %{message_id: _message_id, updates: _updates}}, socket) do
    # Message flags were updated via IMAP, refresh current tab to show changes
    mailbox = socket.assigns.mailbox

    socket =
      assign(socket, :unread_count, Email.unread_count(mailbox.id))
      |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox.id))
      |> assign(:digest_count, Cached.unread_feed_count(mailbox.id))
      |> assign(:ledger_count, Cached.unread_ledger_count(mailbox.id))
      |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox.id))
      |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox.id))
      |> load_tab_content(socket.assigns.current_tab, %{})

    {:noreply, socket}
  end

  def handle_info({:message_updated, _updated_message}, socket) do
    # Message was updated (moved, deleted, etc.), refresh current tab
    socket = load_tab_content(socket, socket.assigns.current_tab, %{})
    {:noreply, socket}
  end

  def handle_info({:message_deleted, _message_id}, socket) do
    # Message was deleted via IMAP, refresh current tab to remove it
    mailbox = socket.assigns.mailbox

    socket =
      assign(socket, :unread_count, Email.unread_count(mailbox.id))
      |> assign(:inbox_unread_count, Cached.unread_inbox_count(mailbox.id))
      |> assign(:digest_count, Cached.unread_feed_count(mailbox.id))
      |> assign(:ledger_count, Cached.unread_ledger_count(mailbox.id))
      |> assign(:stack_unread_count, Cached.unread_stack_count(mailbox.id))
      |> assign(:boomerang_unread_count, Cached.unread_reply_later_count(mailbox.id))
      |> load_tab_content(socket.assigns.current_tab, %{})

    {:noreply, socket}
  end

  @impl true
  def handle_info(_message, socket) do
    # Ignore other messages from PubSub that we don't handle
    # (e.g., chat notifications, other user events)
    {:noreply, socket}
  end

  defp get_or_create_mailbox(user) do
    case Email.get_user_mailbox(user.id) do
      nil ->
        {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
        mailbox

      mailbox ->
        mailbox
    end
  end

  defp load_tab_content(socket, tab, params, page \\ 1) do
    mailbox = socket.assigns.mailbox
    user = socket.assigns.current_user
    per_page = 20

    case tab do
      "inbox" ->
        filter = params["filter"] || "inbox"

        socket =
          if filter == "aliases" do
            # Handle aliases specially - no pagination needed
            aliases = Email.list_aliases(user.id)
            alias_changeset = Email.change_alias(%Email.Alias{})
            mailbox_changeset = Email.change_mailbox_forwarding(mailbox)

            socket
            |> assign(:aliases, aliases)
            |> assign(:alias_form, to_form(alias_changeset))
            |> assign(:mailbox_form, to_form(mailbox_changeset))
            |> assign(:messages, [])
            |> assign(:pagination, %{
              page: 1,
              per_page: per_page,
              total_count: 0,
              total_pages: 0,
              has_next: false,
              has_prev: false
            })
          else
            pagination = load_inbox_messages_paginated(mailbox.id, filter, page, per_page)

            socket
            |> assign(:messages, pagination.messages)
            |> assign(:pagination, pagination)
          end

        socket
        |> assign(:current_filter, filter)

      "sent" ->
        pagination = Email.list_sent_messages_paginated(mailbox.id, page, per_page)

        socket
        |> assign(:messages, pagination.messages)
        |> assign(:pagination, pagination)

      "drafts" ->
        pagination = Email.list_drafts_messages_paginated(mailbox.id, page, per_page)

        socket
        |> assign(:messages, pagination.messages)
        |> assign(:pagination, pagination)

      "spam" ->
        pagination = Email.list_spam_messages_paginated(mailbox.id, page, per_page)

        socket
        |> assign(:messages, pagination.messages)
        |> assign(:pagination, pagination)

      "trash" ->
        pagination = Email.list_trash_messages_paginated(mailbox.id, page, per_page)

        socket
        |> assign(:messages, pagination.messages)
        |> assign(:pagination, pagination)

      "archive" ->
        pagination = Email.list_archived_messages_paginated(mailbox.id, page, per_page)

        socket
        |> assign(:messages, pagination.messages)
        |> assign(:pagination, pagination)

      "search" ->
        query = params["q"] || ""

        results =
          if String.trim(query) != "" do
            Email.search_messages(mailbox.id, query, page, per_page)
          else
            %{
              messages: [],
              total_count: 0,
              page: page,
              per_page: per_page,
              total_pages: 0,
              has_next: false,
              has_prev: false
            }
          end

        socket
        |> assign(:search_query, query)
        |> assign(:search_results, results)
        |> assign(:messages, results.messages || [])
        |> assign(:pagination, results)
        |> assign(:selected_messages, [])
        |> assign(:select_all, false)

      "contacts" ->
        socket
        |> assign(:contacts, Elektrine.Email.Contacts.list_contacts(user.id))
        |> assign(:groups, Elektrine.Email.Contacts.list_contact_groups(user.id))
        |> assign(:contact_search_query, "")
        |> assign(:filter_group_id, nil)
        |> assign(:show_contact_modal, false)
        |> assign(:editing_contact, nil)
        |> assign(:show_group_modal, false)
        |> assign(:editing_group, nil)
        |> assign(:messages, [])
        |> assign(:pagination, %{
          page: 1,
          per_page: per_page,
          total_count: 0,
          total_pages: 0,
          has_next: false,
          has_prev: false
        })

      "calendar" ->
        view_date = socket.assigns[:view_date] || Date.utc_today()
        {:ok, default_calendar} = Cal.get_or_create_default_calendar(user.id)
        calendars = Cal.list_calendars(user.id)
        {start_date, end_date} = get_month_range(view_date)
        events = Cal.list_user_events_in_range(user.id, start_date, end_date)

        visible_calendars =
          case socket.assigns[:visible_calendars] do
            %MapSet{} = existing ->
              if MapSet.size(existing) > 0 do
                existing
              else
                MapSet.new(Enum.map(calendars, & &1.id))
              end

            _ ->
              MapSet.new(Enum.map(calendars, & &1.id))
          end

        socket
        |> assign(:calendars, calendars)
        |> assign(:default_calendar, default_calendar)
        |> assign(:events, events)
        |> assign(:visible_calendars, visible_calendars)
        |> assign(:selected_date, nil)
        |> assign(:selected_event, nil)
        |> assign(:messages, [])
        |> assign(:pagination, %{
          page: 1,
          per_page: per_page,
          total_count: 0,
          total_pages: 0,
          has_next: false,
          has_prev: false
        })

      "folder" ->
        folder_id = params["folder_id"]

        result =
          if folder_id do
            Email.list_folder_messages(String.to_integer(folder_id), user.id, page, per_page)
          else
            %{
              messages: [],
              total: 0,
              page: page,
              per_page: per_page,
              has_next: false,
              has_prev: false
            }
          end

        total_pages = if result.total > 0, do: ceil(result.total / per_page), else: 0

        socket
        |> assign(:messages, result.messages)
        |> assign(:current_folder_id, folder_id)
        |> assign(:pagination, %{
          page: page,
          per_page: per_page,
          total_count: result.total,
          total_pages: total_pages,
          has_next: result.has_next,
          has_prev: result.has_prev
        })

      _ ->
        socket
        |> assign(:pagination, %{
          page: 1,
          per_page: per_page,
          total_count: 0,
          total_pages: 0,
          has_next: false,
          has_prev: false
        })
    end
    |> assign(:selected_messages, [])
    |> assign(:select_all, false)
  end

  defp load_inbox_messages_paginated(mailbox_id, filter, page, per_page) do
    case filter do
      "unread" ->
        # Use efficient paginated query
        Email.list_unread_messages_paginated(mailbox_id, page, per_page)

      "read" ->
        # Use efficient paginated query
        Email.list_read_messages_paginated(mailbox_id, page, per_page)

      "digest" ->
        # Use existing paginated function
        Email.list_feed_messages_paginated(mailbox_id, page, per_page)

      "ledger" ->
        # Use existing paginated function
        Email.list_ledger_messages_paginated(mailbox_id, page, per_page)

      "stack" ->
        # Use existing paginated function
        Email.list_stack_messages_paginated(mailbox_id, page, per_page)

      "boomerang" ->
        # Use existing paginated function
        Email.list_reply_later_messages_paginated(mailbox_id, page, per_page)

      _ ->
        # Use proper inbox messages pagination
        Email.list_inbox_messages_paginated(mailbox_id, page, per_page)
    end
  end

  defp get_page_title(tab, _params \\ %{}) do
    case tab do
      "inbox" -> "Inbox"
      "sent" -> "Sent"
      "spam" -> "Spam"
      "trash" -> "Trash"
      "archive" -> "Archive"
      "search" -> "Search"
      "stack" -> "Stack"
      "digest" -> "Digest"
      "ledger" -> "Ledger"
      "boomerang" -> "Boomerang"
      "contacts" -> "Contacts"
      "calendar" -> "Calendar"
      "folder" -> "Folder"
      _ -> "Email"
    end
  end

  # Helper functions for the template
  defp get_tab_icon(tab) do
    case tab do
      "inbox" -> "hero-inbox"
      "digest" -> "hero-inbox-stack"
      "ledger" -> "hero-document-text"
      "stack" -> "hero-archive-box"
      "boomerang" -> "hero-arrow-uturn-left"
      "sent" -> "hero-paper-airplane"
      "spam" -> "hero-exclamation-triangle"
      "trash" -> "hero-trash"
      "archive" -> "hero-archive-box"
      "search" -> "hero-magnifying-glass"
      "aliases" -> "hero-at-symbol"
      "contacts" -> "hero-user-group"
      "calendar" -> "hero-calendar"
      _ -> "hero-inbox"
    end
  end

  defp get_tab_title(tab) do
    case tab do
      "inbox" -> gettext("Inbox")
      "digest" -> gettext("Digest")
      "ledger" -> gettext("Ledger")
      "stack" -> gettext("Stack")
      "boomerang" -> gettext("Boomerang")
      "sent" -> gettext("Sent")
      "spam" -> gettext("Spam")
      "trash" -> gettext("Trash")
      "archive" -> gettext("Archive")
      "search" -> gettext("Search")
      "aliases" -> gettext("Email Aliases")
      "contacts" -> gettext("Contacts")
      "calendar" -> gettext("Calendar")
      _ -> gettext("Email")
    end
  end

  defp get_tab_description(tab) do
    case tab do
      "inbox" ->
        gettext("Your incoming messages")

      "digest" ->
        gettext("Newsletters, updates, and automated messages from services and subscriptions")

      "ledger" ->
        gettext("Receipts, invoices, and financial records automatically filed for you")

      "stack" ->
        gettext("Messages you've manually saved to process when you have more time")

      "boomerang" ->
        gettext("Messages you've scheduled to be reminded about for replies")

      "sent" ->
        gettext("Messages you have sent")

      "spam" ->
        gettext("Spam and junk messages")

      "archive" ->
        gettext("Archived messages")

      "search" ->
        gettext("Search through your messages")

      "aliases" ->
        gettext("Manage your email aliases and forwarding rules")

      "contacts" ->
        gettext("Manage your email contacts")

      "calendar" ->
        gettext("Manage your events and calendars")

      _ ->
        gettext("Your email messages")
    end
  end

  defp get_message_classes(message, current_tab) do
    base_classes = "bg-base-200 border-base-300"

    cond do
      message.status == "received" and !message.read ->
        "#{base_classes} border-l-4 border-l-primary bg-primary/5"

      current_tab == "spam" ->
        "#{base_classes} border-l-4 border-l-warning bg-warning/5"

      current_tab == "archive" ->
        "#{base_classes} border-l-4 border-l-info bg-info/5"

      true ->
        base_classes
    end
  end

  defp get_empty_message(tab) do
    case tab do
      "inbox" -> gettext("No messages in your inbox")
      "digest" -> gettext("No digest emails")
      "ledger" -> gettext("No receipts or records")
      "stack" -> gettext("Stack is empty")
      "boomerang" -> gettext("Nothing scheduled")
      "sent" -> gettext("No sent messages")
      "spam" -> gettext("No spam messages")
      "archive" -> gettext("No archived messages")
      "search" -> gettext("No search results")
      "aliases" -> gettext("No email aliases")
      "calendar" -> gettext("No events for this month")
      _ -> gettext("No messages")
    end
  end

  defp get_empty_description(tab) do
    case tab do
      "inbox" ->
        gettext("When you receive emails, they will appear here")

      "digest" ->
        gettext(
          "Your daily digest of newsletters, updates, and notifications from subscriptions and services - all automatically organized in one place."
        )

      "ledger" ->
        gettext(
          "Your automatic filing cabinet for receipts, invoices, and financial records. Never lose an important transaction again."
        )

      "stack" ->
        gettext(
          "Your personal stack of saved emails. Use the 'Stack' action to save messages here for when you have more time."
        )

      "boomerang" ->
        gettext(
          "Schedule reminders for emails that need replies. Use the 'Boomerang' action on any message to set a follow-up reminder."
        )

      "sent" ->
        gettext("Messages you send will appear here")

      "spam" ->
        gettext("Spam messages will be moved here automatically")

      "archive" ->
        gettext("Archived messages will appear here")

      "search" ->
        gettext("Try searching for a specific term")

      "aliases" ->
        gettext(
          "Create email aliases to organize your incoming mail and forward emails to different addresses."
        )

      _ ->
        gettext("Your messages will appear here")
    end
  end

  # Calendar helpers
  defp get_month_range(date) do
    first_of_month = Date.beginning_of_month(date)
    last_of_month = Date.end_of_month(date)

    days_since_sunday = Date.day_of_week(first_of_month, :sunday) - 1
    start_date = Date.add(first_of_month, -days_since_sunday)

    days_until_saturday = 7 - Date.day_of_week(last_of_month, :sunday)
    end_date = Date.add(last_of_month, days_until_saturday)

    start_datetime = DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC")
    end_datetime = DateTime.new!(end_date, ~T[23:59:59], "Etc/UTC")

    {start_datetime, end_datetime}
  end

  defp get_month_date_range(date) do
    first_of_month = Date.beginning_of_month(date)
    last_of_month = Date.end_of_month(date)

    days_since_sunday = Date.day_of_week(first_of_month, :sunday) - 1
    start_date = Date.add(first_of_month, -days_since_sunday)

    days_until_saturday = 7 - Date.day_of_week(last_of_month, :sunday)
    end_date = Date.add(last_of_month, days_until_saturday)

    {start_date, end_date}
  end

  defp get_calendar_weeks(date) do
    {start_date, end_date} = get_month_date_range(date)

    start_date
    |> Stream.iterate(&Date.add(&1, 1))
    |> Stream.take_while(&(Date.compare(&1, end_date) != :gt))
    |> Enum.chunk_every(7)
  end

  defp events_for_date(events, date, visible_calendars) do
    events
    |> Enum.filter(fn event ->
      MapSet.member?(visible_calendars, event.calendar_id) and
        (Date.compare(Date.from_iso8601!(Date.to_iso8601(event.dtstart)), date) == :eq or
           (event.dtend && date_in_range?(date, event.dtstart, event.dtend)))
    end)
    |> Enum.sort_by(& &1.dtstart)
  end

  defp date_in_range?(date, start_dt, end_dt) do
    start_date = Date.from_iso8601!(Date.to_iso8601(start_dt))
    end_date = Date.from_iso8601!(Date.to_iso8601(end_dt))
    Date.compare(date, start_date) != :lt and Date.compare(date, end_date) != :gt
  end

  defp format_time(nil), do: ""
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")

  defp month_name(date) do
    Calendar.strftime(date, "%B %Y")
  end

  defp day_class(date, current_date, view_date) do
    cond do
      Date.compare(date, current_date) == :eq -> "bg-primary text-primary-content"
      date.month != view_date.month -> "text-base-content/30"
      true -> ""
    end
  end

  # Generate pagination page range for display
  defp pagination_range(current_page, total_pages) do
    cond do
      total_pages <= 7 ->
        # Show all pages if 7 or fewer
        1..total_pages

      current_page <= 4 ->
        # Show first 5 pages + ellipsis + last page
        1..5

      current_page >= total_pages - 3 ->
        # Show first page + ellipsis + last 5 pages
        (total_pages - 4)..total_pages

      true ->
        # Show first page + ellipsis + current page ± 1 + ellipsis + last page
        (current_page - 1)..(current_page + 1)
    end
  end

  # Get urgency summary for boomerang messages
  defp get_boomerang_urgency_summary(messages) do
    now = DateTime.utc_now()

    counts =
      Enum.reduce(messages, %{overdue: 0, today: 0, upcoming: 0}, fn message, acc ->
        case message.reply_later_at do
          %DateTime{} = datetime ->
            diff_seconds = DateTime.diff(datetime, now)
            diff_hours = div(diff_seconds, 3600)

            cond do
              diff_seconds < 0 -> Map.update!(acc, :overdue, &(&1 + 1))
              diff_hours < 24 -> Map.update!(acc, :today, &(&1 + 1))
              true -> Map.update!(acc, :upcoming, &(&1 + 1))
            end

          _ ->
            acc
        end
      end)

    [
      {gettext("Overdue"), counts.overdue, "badge-error"},
      {gettext("Due Today"), counts.today, "badge-secondary"},
      {gettext("Upcoming"), counts.upcoming, "badge-info"}
    ]
  end
end
