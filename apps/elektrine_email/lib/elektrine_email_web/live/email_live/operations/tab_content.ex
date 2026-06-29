defmodule ElektrineEmailWeb.EmailLive.Operations.TabContent do
  @moduledoc """
  Canonical loader for inbox tab content.

  This is the single source of truth for what each tab shows. It is shared by
  the inbox LiveView (`EmailLive.Index`) and every operation module that needs
  to refresh the current tab after an action - previously each kept its own
  drifted copy.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 1]

  alias Elektrine.Calendar, as: Cal
  alias Elektrine.Email
  alias Elektrine.Email.Cached
  alias Elektrine.Telemetry.Events
  alias ElektrineEmailWeb.EmailLive.EmailHelpers

  def load_tab_content(socket, tab, params, page \\ 1) do
    started_at = System.monotonic_time(:millisecond)
    mailbox = socket.assigns.mailbox
    user = socket.assigns.current_user
    per_page = 20

    socket =
      case tab do
        "inbox" ->
          filter = normalize_inbox_filter(mailbox, params["filter"] || "inbox")

          socket =
            if filter == "aliases" do
              # Handle aliases specially - no pagination needed
              aliases = Cached.get_aliases(user.id)
              alias_changeset = Email.change_alias(%Email.Alias{})
              mailbox_changeset = Email.change_mailbox_forwarding(mailbox)

              socket
              |> assign(:aliases, aliases)
              |> assign(:alias_form, to_form(alias_changeset))
              |> assign(:mailbox_form, to_form(mailbox_changeset))
              |> assign(:messages, [])
              |> assign(:pagination, empty_pagination(per_page))
            else
              pagination = load_inbox_messages_paginated(mailbox.id, filter, page, per_page)

              socket
              |> assign(:messages, pagination.messages)
              |> assign(:pagination, pagination)
            end

          socket
          |> assign(:current_filter, filter)

        "sent" ->
          pagination = Cached.list_sent_messages_paginated(mailbox.id, page, per_page)

          socket
          |> assign(:messages, pagination.messages)
          |> assign(:pagination, pagination)

        "drafts" ->
          pagination = Cached.list_drafts_messages_paginated(mailbox.id, page, per_page)

          socket
          |> assign(:messages, pagination.messages)
          |> assign(:pagination, pagination)

        "spam" ->
          pagination = Cached.list_spam_messages_paginated(mailbox.id, page, per_page)

          socket
          |> assign(:messages, pagination.messages)
          |> assign(:pagination, pagination)

        "trash" ->
          pagination = Cached.list_trash_messages_paginated(mailbox.id, page, per_page)

          socket
          |> assign(:messages, pagination.messages)
          |> assign(:pagination, pagination)

        "archive" ->
          pagination = Cached.list_archived_messages_paginated(mailbox.id, page, per_page)

          socket
          |> assign(:messages, pagination.messages)
          |> assign(:pagination, pagination)

        "search" ->
          query = params["q"] || ""

          results =
            if Elektrine.Strings.present?(query) do
              Cached.search_messages(user.id, mailbox.id, query, page, per_page)
            else
              empty_pagination(per_page) |> Map.put(:page, page)
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
          |> assign(:pagination, empty_pagination(per_page))

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
          |> assign(:pagination, empty_pagination(per_page))

        "folder" ->
          folder_id = params["folder_id"] || socket.assigns[:current_folder_id]
          parsed_folder_id = parse_positive_int(folder_id)

          result =
            if parsed_folder_id do
              Cached.list_folder_messages(
                mailbox.id,
                parsed_folder_id,
                user.id,
                page,
                per_page
              )
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

          total_pages =
            if result.total > 0, do: ceil(result.total / per_page), else: 0

          socket
          |> assign(:messages, result.messages)
          |> assign(:current_folder_id, parsed_folder_id)
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
          |> assign(:pagination, empty_pagination(per_page))
      end

    # The inbox/unread/read loaders already group by thread in SQL and carry the
    # whole-thread state, so re-grouping here would recompute that state from the
    # single head message and get it wrong. Other tabs still group in Elixir.
    grouped_messages =
      (socket.assigns[:messages] || [])
      |> maybe_group_messages(tab, socket.assigns[:current_filter])
      |> attach_preview_text()

    Events.db_hot_path(
      :email_live,
      :load_tab_content,
      System.monotonic_time(:millisecond) - started_at,
      %{tab: tab, page: page, mailbox_id: mailbox.id}
    )

    socket
    |> assign(:messages, grouped_messages)
    |> assign(:selected_messages, [])
    |> assign(:select_all, false)
  end

  def current_tab_params(socket) do
    %{}
    |> maybe_put_param("filter", socket.assigns[:current_filter])
    |> maybe_put_param("folder_id", socket.assigns[:current_folder_id])
    |> maybe_put_param("q", socket.assigns[:search_query])
  end

  defp parse_positive_int(nil), do: nil

  defp parse_positive_int(value) do
    case Integer.parse(to_string(value)) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  def message_attachment_total(%{attachments: attachments}) when is_map(attachments),
    do: map_size(attachments)

  def message_attachment_total(_), do: 0

  defp empty_pagination(per_page) do
    %{
      messages: [],
      page: 1,
      per_page: per_page,
      total_count: 0,
      total_pages: 0,
      has_next: false,
      has_prev: false
    }
  end

  defp maybe_put_param(params, _key, nil), do: params
  defp maybe_put_param(params, _key, ""), do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  defp normalize_inbox_filter(mailbox, "digest") do
    if Elektrine.Email.Mailbox.digest_filter_enabled?(mailbox), do: "digest", else: "inbox"
  end

  defp normalize_inbox_filter(mailbox, "ledger") do
    if Elektrine.Email.Mailbox.ledger_filter_enabled?(mailbox), do: "ledger", else: "inbox"
  end

  defp normalize_inbox_filter(_mailbox, filter), do: filter

  defp load_inbox_messages_paginated(mailbox_id, filter, page, per_page) do
    case filter do
      "unread" ->
        Cached.list_unread_messages_paginated(mailbox_id, page, per_page)

      "read" ->
        Cached.list_read_messages_paginated(mailbox_id, page, per_page)

      "digest" ->
        Cached.list_feed_messages_paginated(mailbox_id, page, per_page)

      "ledger" ->
        Cached.list_ledger_messages_paginated(mailbox_id, page, per_page)

      "stack" ->
        Cached.list_stack_messages_paginated(mailbox_id, page, per_page)

      "boomerang" ->
        Cached.list_reply_later_messages_paginated(mailbox_id, page, per_page)

      _ ->
        Cached.list_inbox_messages_paginated(mailbox_id, page, per_page)
    end
  end

  # Inbox/unread/read are already thread-grouped by the SQL loader; everything
  # else still groups in Elixir from a flat message list.
  defp maybe_group_messages(messages, "inbox", filter)
       when filter in ["inbox", "unread", "read"],
       do: messages

  defp maybe_group_messages(messages, tab, _filter), do: group_messages_for_list(messages, tab)

  defp group_messages_for_list(messages, tab)
       when tab in ["contacts", "calendar", "drafts", "aliases"] do
    messages
  end

  defp group_messages_for_list(messages, _tab) when is_list(messages) do
    {ordered_keys, grouped} =
      Enum.reduce(messages, {[], %{}}, fn message, {keys, acc} ->
        key = message_thread_group_key(message)
        unread = message.status == "received" and !message.read
        attachment_total = message_attachment_total(message)

        case Map.get(acc, key) do
          nil ->
            group = %{
              head: message,
              count: 1,
              unread_count: if(unread, do: 1, else: 0),
              has_unread: unread,
              has_attachments: message.has_attachments || attachment_total > 0,
              attachment_total: attachment_total
            }

            {[key | keys], Map.put(acc, key, group)}

          group ->
            updated_group = %{
              group
              | count: group.count + 1,
                unread_count: group.unread_count + if(unread, do: 1, else: 0),
                has_unread: group.has_unread || unread,
                has_attachments:
                  group.has_attachments || message.has_attachments || attachment_total > 0,
                attachment_total: group.attachment_total + attachment_total
            }

            {keys, Map.put(acc, key, updated_group)}
        end
      end)

    ordered_keys
    |> Enum.reverse()
    |> Enum.map(fn key ->
      group = Map.fetch!(grouped, key)

      group.head
      |> Map.put(:thread_message_count, group.count)
      |> Map.put(:thread_unread_count, group.unread_count)
      |> Map.put(:thread_has_unread, group.has_unread)
      |> Map.put(:thread_has_attachments, group.has_attachments)
      |> Map.put(:thread_attachment_total, group.attachment_total)
    end)
  end

  defp group_messages_for_list(messages, _tab), do: messages

  defp message_thread_group_key(message) do
    case Map.get(message, :thread_id) do
      thread_id when is_integer(thread_id) and thread_id > 0 ->
        {:thread, thread_id}

      _ ->
        {:message, message.id}
    end
  end

  # Previews involve regex/entity decoding, so compute them once per load
  # rather than once per message per render.
  defp attach_preview_text(messages) when is_list(messages) do
    Enum.map(messages, &Map.put(&1, :preview_text, EmailHelpers.email_preview(&1)))
  end

  defp attach_preview_text(messages), do: messages

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
end
