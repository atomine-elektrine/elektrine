defmodule Elektrine.JMAP do
  @moduledoc """
  Main JMAP context module. Provides the public API for JMAP operations.
  """

  alias Elektrine.JMAP.{Thread, State, EmailSubmission}
  alias Elektrine.Email.{Mailbox, Message}
  alias Elektrine.Repo

  import Ecto.Query

  # ============================================================================
  # Thread Operations
  # ============================================================================

  @doc """
  Assigns a thread to a message based on headers and subject.
  """
  defdelegate assign_thread(attrs, mailbox_id), to: Thread

  @doc """
  Gets a thread by ID.
  """
  defdelegate get_thread(thread_id, mailbox_id), to: Thread

  @doc """
  Gets all message IDs in a thread.
  """
  defdelegate get_thread_message_ids(thread_id), to: Thread

  # ============================================================================
  # State Operations
  # ============================================================================

  @doc """
  Gets the current state for an entity type.
  """
  defdelegate get_state(mailbox_id, entity_type), to: State

  @doc """
  Increments state and returns new state string.
  """
  defdelegate increment_state(mailbox_id, entity_type), to: State

  @doc """
  Validates a state string.
  """
  defdelegate validate_state(mailbox_id, entity_type, since_state), to: State

  # ============================================================================
  # EmailSubmission Operations
  # ============================================================================

  @doc """
  Creates a new email submission.
  """
  defdelegate create_submission(attrs), to: EmailSubmission, as: :create

  @doc """
  Gets an email submission by ID.
  """
  defdelegate get_submission(id, mailbox_id), to: EmailSubmission, as: :get

  @doc """
  Lists email submissions.
  """
  defdelegate list_submissions(mailbox_id, opts \\ []), to: EmailSubmission, as: :list

  # ============================================================================
  # JMAP Mailbox Operations (Virtual Mailboxes from Categories)
  # ============================================================================

  @doc """
  Gets all JMAP mailboxes (virtual folders) for a user.
  Maps Elektrine categories and flags to JMAP mailbox concepts.
  """
  def get_mailboxes(mailbox_id) do
    mailbox = Repo.get(Mailbox, mailbox_id)
    if is_nil(mailbox), do: [], else: build_virtual_mailboxes(mailbox)
  end

  # Build virtual JMAP mailboxes from Elektrine's category/flag system
  defp build_virtual_mailboxes(mailbox) do
    base_id = "mb-#{mailbox.id}"

    [
      %{
        id: "#{base_id}-inbox",
        name: "Inbox",
        role: "inbox",
        sort_order: 1,
        total_emails: count_messages(mailbox.id, :inbox),
        unread_emails: count_unread(mailbox.id, :inbox),
        is_subscribed: true
      },
      %{
        id: "#{base_id}-feed",
        name: "Feed",
        role: nil,
        sort_order: 2,
        total_emails: count_messages(mailbox.id, :feed),
        unread_emails: count_unread(mailbox.id, :feed),
        is_subscribed: true
      },
      %{
        id: "#{base_id}-ledger",
        name: "Ledger",
        role: nil,
        sort_order: 3,
        total_emails: count_messages(mailbox.id, :ledger),
        unread_emails: count_unread(mailbox.id, :ledger),
        is_subscribed: true
      },
      %{
        id: "#{base_id}-stack",
        name: "Stack",
        role: nil,
        sort_order: 4,
        total_emails: count_messages(mailbox.id, :stack),
        unread_emails: count_unread(mailbox.id, :stack),
        is_subscribed: true
      },
      %{
        id: "#{base_id}-sent",
        name: "Sent",
        role: "sent",
        sort_order: 10,
        total_emails: count_messages(mailbox.id, :sent),
        unread_emails: 0,
        is_subscribed: true
      },
      %{
        id: "#{base_id}-drafts",
        name: "Drafts",
        role: "drafts",
        sort_order: 11,
        total_emails: count_messages(mailbox.id, :drafts),
        unread_emails: 0,
        is_subscribed: true
      },
      %{
        id: "#{base_id}-trash",
        name: "Trash",
        role: "trash",
        sort_order: 20,
        total_emails: count_messages(mailbox.id, :trash),
        unread_emails: count_unread(mailbox.id, :trash),
        is_subscribed: true
      },
      %{
        id: "#{base_id}-spam",
        name: "Spam",
        role: "junk",
        sort_order: 21,
        total_emails: count_messages(mailbox.id, :spam),
        unread_emails: count_unread(mailbox.id, :spam),
        is_subscribed: true
      },
      %{
        id: "#{base_id}-archive",
        name: "Archive",
        role: "archive",
        sort_order: 30,
        total_emails: count_messages(mailbox.id, :archive),
        unread_emails: count_unread(mailbox.id, :archive),
        is_subscribed: true
      }
    ]
  end

  # Count messages in a virtual folder
  defp count_messages(mailbox_id, folder) do
    query = base_folder_query(mailbox_id, folder)
    Repo.aggregate(query, :count, :id)
  end

  # Count unread messages in a virtual folder
  defp count_unread(mailbox_id, folder) do
    query =
      mailbox_id
      |> base_folder_query(folder)
      |> where([m], m.read == false)

    Repo.aggregate(query, :count, :id)
  end

  # Build base query for each virtual folder type
  defp base_folder_query(mailbox_id, :inbox) do
    from m in Message,
      where:
        m.mailbox_id == ^mailbox_id and
          m.category == "inbox" and
          m.deleted == false and
          m.spam == false and
          m.archived == false and
          m.status == "received"
  end

  defp base_folder_query(mailbox_id, :feed) do
    from m in Message,
      where:
        m.mailbox_id == ^mailbox_id and
          m.category == "feed" and
          m.deleted == false and
          m.spam == false
  end

  defp base_folder_query(mailbox_id, :ledger) do
    from m in Message,
      where:
        m.mailbox_id == ^mailbox_id and
          m.category == "ledger" and
          m.deleted == false and
          m.spam == false
  end

  defp base_folder_query(mailbox_id, :stack) do
    from m in Message,
      where:
        m.mailbox_id == ^mailbox_id and
          m.category == "stack" and
          m.deleted == false and
          m.spam == false
  end

  defp base_folder_query(mailbox_id, :sent) do
    from m in Message,
      where:
        m.mailbox_id == ^mailbox_id and
          m.status == "sent" and
          m.deleted == false
  end

  defp base_folder_query(mailbox_id, :drafts) do
    from m in Message,
      where:
        m.mailbox_id == ^mailbox_id and
          m.status == "draft" and
          m.deleted == false
  end

  defp base_folder_query(mailbox_id, :trash) do
    from m in Message,
      where: m.mailbox_id == ^mailbox_id and m.deleted == true
  end

  defp base_folder_query(mailbox_id, :spam) do
    from m in Message,
      where:
        m.mailbox_id == ^mailbox_id and
          m.spam == true and
          m.deleted == false
  end

  defp base_folder_query(mailbox_id, :archive) do
    from m in Message,
      where:
        m.mailbox_id == ^mailbox_id and
          m.archived == true and
          m.deleted == false and
          m.spam == false
  end

  # ============================================================================
  # JMAP Email Operations
  # ============================================================================

  @doc """
  Gets emails by IDs with JMAP property mapping.
  """
  def get_emails(mailbox_id, email_ids, properties \\ nil) do
    messages =
      Repo.all(
        from m in Message,
          where: m.mailbox_id == ^mailbox_id and m.id in ^email_ids
      )

    Enum.map(messages, &message_to_jmap_email(&1, properties))
  end

  @doc """
  Queries emails with JMAP filter and sort options.
  """
  def query_emails(mailbox_id, opts \\ []) do
    filter = Keyword.get(opts, :filter, %{})
    sort = Keyword.get(opts, :sort, [%{"property" => "receivedAt", "isAscending" => false}])
    limit = Keyword.get(opts, :limit, 50)
    position = Keyword.get(opts, :position, 0)

    query =
      from m in Message,
        where: m.mailbox_id == ^mailbox_id

    query = apply_jmap_filter(query, filter, mailbox_id)
    query = apply_jmap_sort(query, sort)

    total = Repo.aggregate(query, :count, :id)

    ids =
      query
      |> limit(^limit)
      |> offset(^position)
      |> select([m], m.id)
      |> Repo.all()

    %{
      ids: ids,
      total: total,
      position: position
    }
  end

  # Apply JMAP filter to query
  defp apply_jmap_filter(query, filter, mailbox_id) when is_map(filter) do
    Enum.reduce(filter, query, fn
      {"inMailbox", mailbox_jmap_id}, q ->
        apply_mailbox_filter(q, mailbox_jmap_id, mailbox_id)

      {"from", from}, q ->
        where(q, [m], ilike(m.from, ^"%#{from}%"))

      {"to", to}, q ->
        where(q, [m], ilike(m.to, ^"%#{to}%"))

      {"subject", subject}, q ->
        where(q, [m], ilike(m.subject, ^"%#{subject}%"))

      {"hasKeyword", "$seen"}, q ->
        where(q, [m], m.read == true)

      {"hasKeyword", "$flagged"}, q ->
        where(q, [m], m.flagged == true)

      {"hasKeyword", "$draft"}, q ->
        where(q, [m], m.status == "draft")

      {"notKeyword", "$seen"}, q ->
        where(q, [m], m.read == false)

      {"notKeyword", "$flagged"}, q ->
        where(q, [m], m.flagged == false)

      {"before", datetime}, q ->
        {:ok, dt, _} = DateTime.from_iso8601(datetime)
        where(q, [m], m.inserted_at < ^dt)

      {"after", datetime}, q ->
        {:ok, dt, _} = DateTime.from_iso8601(datetime)
        where(q, [m], m.inserted_at > ^dt)

      {"minSize", _size}, q ->
        # Approximate size check (would need to compute actual size)
        q

      {"maxSize", _size}, q ->
        q

      {"hasAttachment", true}, q ->
        where(q, [m], m.has_attachments == true)

      {"hasAttachment", false}, q ->
        where(q, [m], m.has_attachments == false)

      _, q ->
        q
    end)
  end

  defp apply_jmap_filter(query, _, _), do: query

  # Apply mailbox filter (maps JMAP mailbox ID to query conditions)
  defp apply_mailbox_filter(query, jmap_mailbox_id, _mailbox_id) do
    # Parse the JMAP mailbox ID to determine the folder type
    cond do
      String.ends_with?(jmap_mailbox_id, "-inbox") ->
        where(
          query,
          [m],
          m.category == "inbox" and m.deleted == false and m.spam == false and m.archived == false and
            m.status == "received"
        )

      String.ends_with?(jmap_mailbox_id, "-feed") ->
        where(query, [m], m.category == "feed" and m.deleted == false and m.spam == false)

      String.ends_with?(jmap_mailbox_id, "-ledger") ->
        where(query, [m], m.category == "ledger" and m.deleted == false and m.spam == false)

      String.ends_with?(jmap_mailbox_id, "-stack") ->
        where(query, [m], m.category == "stack" and m.deleted == false and m.spam == false)

      String.ends_with?(jmap_mailbox_id, "-sent") ->
        where(query, [m], m.status == "sent" and m.deleted == false)

      String.ends_with?(jmap_mailbox_id, "-drafts") ->
        where(query, [m], m.status == "draft" and m.deleted == false)

      String.ends_with?(jmap_mailbox_id, "-trash") ->
        where(query, [m], m.deleted == true)

      String.ends_with?(jmap_mailbox_id, "-spam") ->
        where(query, [m], m.spam == true and m.deleted == false)

      String.ends_with?(jmap_mailbox_id, "-archive") ->
        where(query, [m], m.archived == true and m.deleted == false and m.spam == false)

      true ->
        query
    end
  end

  # Apply JMAP sort options
  defp apply_jmap_sort(query, sort) when is_list(sort) do
    Enum.reduce(sort, query, fn sort_item, q ->
      property = Map.get(sort_item, "property", "receivedAt")
      ascending = Map.get(sort_item, "isAscending", false)
      direction = if ascending, do: :asc, else: :desc

      case property do
        "receivedAt" -> order_by(q, [m], [{^direction, m.inserted_at}])
        "sentAt" -> order_by(q, [m], [{^direction, m.inserted_at}])
        "subject" -> order_by(q, [m], [{^direction, m.subject}])
        "from" -> order_by(q, [m], [{^direction, m.from}])
        _ -> q
      end
    end)
  end

  defp apply_jmap_sort(query, _), do: order_by(query, [m], desc: m.inserted_at)

  # Convert Elektrine Message to JMAP Email format
  defp message_to_jmap_email(message, properties) do
    base = %{
      "id" => to_string(message.id),
      "blobId" => message.jmap_blob_id || "blob-#{message.id}",
      "threadId" =>
        if(message.thread_id, do: to_string(message.thread_id), else: "t-#{message.id}"),
      "mailboxIds" => build_mailbox_ids(message),
      "keywords" => build_keywords(message),
      "receivedAt" => DateTime.to_iso8601(message.inserted_at),
      "messageId" => [message.message_id],
      "inReplyTo" => if(message.in_reply_to, do: [message.in_reply_to], else: nil),
      "references" => if(message.references, do: String.split(message.references), else: nil),
      "from" => parse_address(message.from),
      "to" => parse_addresses(message.to),
      "cc" => parse_addresses(message.cc),
      "bcc" => parse_addresses(message.bcc),
      "subject" => message.subject,
      "hasAttachment" => message.has_attachments,
      "preview" => build_preview(message)
    }

    # Add body parts if requested
    if is_nil(properties) or "textBody" in properties or "htmlBody" in properties do
      base
      |> Map.put(
        "textBody",
        if(message.text_body, do: [%{"value" => message.text_body}], else: [])
      )
      |> Map.put(
        "htmlBody",
        if(message.html_body, do: [%{"value" => message.html_body}], else: [])
      )
    else
      base
    end
  end

  # Build mailboxIds object for a message
  defp build_mailbox_ids(message) do
    base_id = "mb-#{message.mailbox_id}"

    ids = %{}

    # Add primary folder based on status/category
    ids =
      cond do
        message.deleted -> Map.put(ids, "#{base_id}-trash", true)
        message.spam -> Map.put(ids, "#{base_id}-spam", true)
        message.status == "sent" -> Map.put(ids, "#{base_id}-sent", true)
        message.status == "draft" -> Map.put(ids, "#{base_id}-drafts", true)
        message.archived -> Map.put(ids, "#{base_id}-archive", true)
        true -> Map.put(ids, "#{base_id}-#{message.category}", true)
      end

    ids
  end

  # Build keywords object for a message
  defp build_keywords(message) do
    keywords = %{}

    keywords = if message.read, do: Map.put(keywords, "$seen", true), else: keywords
    keywords = if message.flagged, do: Map.put(keywords, "$flagged", true), else: keywords
    keywords = if message.answered, do: Map.put(keywords, "$answered", true), else: keywords
    keywords = if message.status == "draft", do: Map.put(keywords, "$draft", true), else: keywords

    keywords
  end

  # Parse single email address to JMAP format
  defp parse_address(nil), do: nil
  defp parse_address(""), do: nil

  defp parse_address(address) do
    # Simple parsing - in production, use a proper email parser
    case Regex.run(~r/^(.+?)\s*<(.+?)>$/, address) do
      [_, name, email] -> [%{"name" => String.trim(name), "email" => email}]
      _ -> [%{"name" => nil, "email" => address}]
    end
  end

  # Parse multiple email addresses
  defp parse_addresses(nil), do: nil
  defp parse_addresses(""), do: nil

  defp parse_addresses(addresses) do
    addresses
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(&parse_address/1)
  end

  # Build preview text
  defp build_preview(message) do
    text = message.text_body || message.html_body || ""

    text
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 256)
  end
end
