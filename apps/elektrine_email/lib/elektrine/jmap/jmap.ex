defmodule Elektrine.JMAP do
  @moduledoc """
  Main JMAP context module. Provides the public API for JMAP operations.
  """

  alias Elektrine.Email.{Mailbox, Message}
  alias Elektrine.JMAP.{EmailChange, EmailSubmission, EmailTombstone, State, Thread}
  alias Elektrine.PubSub
  alias Elektrine.Repo

  import Ecto.Query

  @supported_state_types ~w(Mailbox Email Thread EmailSubmission)

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
  def get_thread_message_ids(thread_id, mailbox_id \\ nil),
    do: Thread.get_thread_message_ids(thread_id, mailbox_id)

  # ============================================================================
  # State Operations
  # ============================================================================

  @doc """
  Gets the current state for an entity type.
  """
  def get_state(mailbox_id, "Email"), do: State.get_state(mailbox_id, "Email")
  def get_state(mailbox_id, entity_type), do: State.get_state(mailbox_id, entity_type)

  @doc """
  Increments state and returns new state string.
  """
  defdelegate increment_state(mailbox_id, entity_type), to: State

  @doc """
  Validates a state string.
  """
  def validate_state(mailbox_id, "Email", since_state) do
    current_counter = State.get_state_counter(mailbox_id, "Email")

    case parse_email_state_counter(since_state) do
      {:ok, since_counter} when since_counter <= current_counter ->
        {:ok, State.get_state(mailbox_id, "Email")}

      _ ->
        {:error, :invalid_state}
    end
  end

  def validate_state(mailbox_id, entity_type, since_state) do
    State.validate_state(mailbox_id, entity_type, since_state)
  end

  @doc """
  Returns a stable session state token derived from the current JMAP-visible states.
  """
  def get_session_state(mailbox_id) do
    payload =
      @supported_state_types
      |> Enum.map(fn type -> "#{type}=#{get_state(mailbox_id, type)}" end)
      |> Enum.join("|")

    payload
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  @doc """
  Increments multiple entity states and broadcasts a compact state-change event.
  """
  def bump_states(mailbox_id, entity_types)
      when is_integer(mailbox_id) and is_list(entity_types) do
    entity_types =
      entity_types
      |> Enum.filter(&(&1 in @supported_state_types))
      |> Enum.uniq()

    Enum.each(entity_types, &State.increment_state(mailbox_id, &1))

    if entity_types != [] do
      Phoenix.PubSub.broadcast(
        PubSub,
        "jmap:#{mailbox_id}",
        {:jmap_state_change, entity_types}
      )
    end

    :ok
  end

  @doc """
  Builds a JMAP StateChange payload for the requested mailbox and types.
  """
  def state_change(mailbox_id, account_id, requested_types \\ @supported_state_types)
      when is_integer(mailbox_id) and is_binary(account_id) do
    changed =
      requested_types
      |> Enum.filter(&(&1 in @supported_state_types))
      |> Enum.uniq()
      |> Enum.into(%{}, fn type -> {type, get_state(mailbox_id, type)} end)

    %{
      "@type" => "StateChange",
      "changed" => %{
        account_id => changed
      }
    }
  end

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
  defdelegate get_submission(id), to: EmailSubmission, as: :get
  defdelegate get_submission(id, mailbox_id), to: EmailSubmission, as: :get

  @doc """
  Gets the most recent submission for an email in a mailbox.
  """
  defdelegate get_submission_by_email(mailbox_id, email_id),
    to: EmailSubmission,
    as: :get_by_email

  @doc """
  Lists email submissions.
  """
  defdelegate list_submissions(mailbox_id, opts \\ []), to: EmailSubmission, as: :list

  @doc """
  Updates an email submission.
  """
  defdelegate update_submission(submission, attrs), to: EmailSubmission, as: :update

  @doc """
  Cancels a pending email submission.
  """
  defdelegate cancel_submission(submission), to: EmailSubmission, as: :cancel

  @doc """
  Marks an email submission as final.
  """
  defdelegate finalize_submission(submission), to: EmailSubmission, as: :finalize

  @doc """
  Marks an email submission as final with delivery metadata.
  """
  defdelegate finalize_submission(submission, delivery_status),
    to: EmailSubmission,
    as: :finalize

  @doc """
  Marks an email submission as failed.
  """
  defdelegate fail_submission(submission, reason), to: EmailSubmission, as: :fail

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
        "id" => "#{base_id}-inbox",
        "name" => "Inbox",
        "role" => "inbox",
        "sortOrder" => 1,
        "totalEmails" => count_messages(mailbox.id, :inbox),
        "unreadEmails" => count_unread(mailbox.id, :inbox),
        "totalThreads" => count_threads(mailbox.id, :inbox),
        "unreadThreads" => count_unread_threads(mailbox.id, :inbox),
        "isSubscribed" => true,
        "parentId" => nil,
        "myRights" => mailbox_rights()
      },
      %{
        "id" => "#{base_id}-feed",
        "name" => "Feed",
        "role" => nil,
        "sortOrder" => 2,
        "totalEmails" => count_messages(mailbox.id, :feed),
        "unreadEmails" => count_unread(mailbox.id, :feed),
        "totalThreads" => count_threads(mailbox.id, :feed),
        "unreadThreads" => count_unread_threads(mailbox.id, :feed),
        "isSubscribed" => true,
        "parentId" => nil,
        "myRights" => mailbox_rights()
      },
      %{
        "id" => "#{base_id}-ledger",
        "name" => "Ledger",
        "role" => nil,
        "sortOrder" => 3,
        "totalEmails" => count_messages(mailbox.id, :ledger),
        "unreadEmails" => count_unread(mailbox.id, :ledger),
        "totalThreads" => count_threads(mailbox.id, :ledger),
        "unreadThreads" => count_unread_threads(mailbox.id, :ledger),
        "isSubscribed" => true,
        "parentId" => nil,
        "myRights" => mailbox_rights()
      },
      %{
        "id" => "#{base_id}-stack",
        "name" => "Stack",
        "role" => nil,
        "sortOrder" => 4,
        "totalEmails" => count_messages(mailbox.id, :stack),
        "unreadEmails" => count_unread(mailbox.id, :stack),
        "totalThreads" => count_threads(mailbox.id, :stack),
        "unreadThreads" => count_unread_threads(mailbox.id, :stack),
        "isSubscribed" => true,
        "parentId" => nil,
        "myRights" => mailbox_rights()
      },
      %{
        "id" => "#{base_id}-sent",
        "name" => "Sent",
        "role" => "sent",
        "sortOrder" => 10,
        "totalEmails" => count_messages(mailbox.id, :sent),
        "unreadEmails" => 0,
        "totalThreads" => count_threads(mailbox.id, :sent),
        "unreadThreads" => 0,
        "isSubscribed" => true,
        "parentId" => nil,
        "myRights" => mailbox_rights()
      },
      %{
        "id" => "#{base_id}-drafts",
        "name" => "Drafts",
        "role" => "drafts",
        "sortOrder" => 11,
        "totalEmails" => count_messages(mailbox.id, :drafts),
        "unreadEmails" => 0,
        "totalThreads" => count_threads(mailbox.id, :drafts),
        "unreadThreads" => 0,
        "isSubscribed" => true,
        "parentId" => nil,
        "myRights" => mailbox_rights()
      },
      %{
        "id" => "#{base_id}-trash",
        "name" => "Trash",
        "role" => "trash",
        "sortOrder" => 20,
        "totalEmails" => count_messages(mailbox.id, :trash),
        "unreadEmails" => count_unread(mailbox.id, :trash),
        "totalThreads" => count_threads(mailbox.id, :trash),
        "unreadThreads" => count_unread_threads(mailbox.id, :trash),
        "isSubscribed" => true,
        "parentId" => nil,
        "myRights" => mailbox_rights()
      },
      %{
        "id" => "#{base_id}-spam",
        "name" => "Spam",
        "role" => "junk",
        "sortOrder" => 21,
        "totalEmails" => count_messages(mailbox.id, :spam),
        "unreadEmails" => count_unread(mailbox.id, :spam),
        "totalThreads" => count_threads(mailbox.id, :spam),
        "unreadThreads" => count_unread_threads(mailbox.id, :spam),
        "isSubscribed" => true,
        "parentId" => nil,
        "myRights" => mailbox_rights()
      },
      %{
        "id" => "#{base_id}-archive",
        "name" => "Archive",
        "role" => "archive",
        "sortOrder" => 30,
        "totalEmails" => count_messages(mailbox.id, :archive),
        "unreadEmails" => count_unread(mailbox.id, :archive),
        "totalThreads" => count_threads(mailbox.id, :archive),
        "unreadThreads" => count_unread_threads(mailbox.id, :archive),
        "isSubscribed" => true,
        "parentId" => nil,
        "myRights" => mailbox_rights()
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

  defp count_threads(mailbox_id, folder) do
    mailbox_id
    |> base_folder_query(folder)
    |> select([m], count(fragment("DISTINCT COALESCE(?, ?)", m.thread_id, m.id)))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp count_unread_threads(mailbox_id, folder) do
    mailbox_id
    |> base_folder_query(folder)
    |> where([m], m.read == false)
    |> select([m], count(fragment("DISTINCT COALESCE(?, ?)", m.thread_id, m.id)))
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp mailbox_rights do
    %{
      "mayReadItems" => true,
      "mayAddItems" => true,
      "mayRemoveItems" => true,
      "maySetSeen" => true,
      "maySetKeywords" => true,
      "mayCreateChild" => false,
      "mayRename" => false,
      "mayDelete" => false,
      "maySubmit" => true
    }
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
      |> decrypt_messages_for_mailbox(mailbox_id)

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

    with {:ok, filter_dynamic} <- build_jmap_filter(filter, mailbox_id),
         {:ok, sorted_query} <- apply_jmap_sort(where(query, ^filter_dynamic), sort) do
      total = Repo.aggregate(sorted_query, :count, :id)

      ids =
        sorted_query
        |> limit(^limit)
        |> offset(^position)
        |> select([m], m.id)
        |> Repo.all()

      {:ok,
       %{
         ids: ids,
         total: total,
         position: position
       }}
    end
  end

  @doc """
  Returns a best-effort set of email changes since the provided state token.
  """
  def email_changes_since(mailbox_id, since_state) do
    with {:ok, since_counter} <- parse_email_state_counter(since_state),
         current_counter <- State.get_state_counter(mailbox_id, "Email"),
         true <- since_counter <= current_counter do
      changes = EmailChange.list_since(mailbox_id, since_counter, current_counter)
      {created_ids, updated_ids, destroyed_ids} = fold_email_changes(changes)

      {:ok,
       %{
         "oldState" => since_state,
         "newState" => State.get_state(mailbox_id, "Email"),
         "hasMoreChanges" => false,
         "created" => Enum.map(created_ids, &to_string/1),
         "updated" => Enum.map(updated_ids, &to_string/1),
         "destroyed" => Enum.map(destroyed_ids, &to_string/1)
       }}
    else
      false -> {:error, :invalid_state}
      _ -> {:error, :invalid_state}
    end
  end

  @doc """
  Records a created email and bumps the related JMAP states.
  """
  def record_email_created(mailbox_id, email_id, extra_entity_types \\ []) do
    record_email_change(mailbox_id, email_id, "created", extra_entity_types)
  end

  @doc """
  Records an updated email and bumps the related JMAP states.
  """
  def record_email_updated(mailbox_id, email_id, extra_entity_types \\ []) do
    record_email_change(mailbox_id, email_id, "updated", extra_entity_types)
  end

  @doc """
  Records a deleted email id for later Email/changes responses.
  """
  def record_email_destroyed(mailbox_id, email_id, extra_entity_types \\ []) do
    _ = EmailTombstone.create(mailbox_id, email_id)
    record_email_change(mailbox_id, email_id, "destroyed", extra_entity_types)
  end

  # Apply JMAP sort options
  defp apply_jmap_sort(query, sort) when is_list(sort) do
    Enum.reduce_while(sort, {:ok, query}, fn sort_item, {:ok, q} ->
      property = Map.get(sort_item, "property", "receivedAt")
      ascending = Map.get(sort_item, "isAscending", false)
      direction = if ascending, do: :asc, else: :desc

      next_query =
        case property do
          "receivedAt" -> {:ok, order_by(q, [m], [{^direction, m.inserted_at}])}
          "sentAt" -> {:ok, order_by(q, [m], [{^direction, m.inserted_at}])}
          "subject" -> {:ok, order_by(q, [m], [{^direction, m.subject}])}
          "from" -> {:ok, order_by(q, [m], [{^direction, m.from}])}
          _ -> {:error, {:unsupported_sort, property}}
        end

      case next_query do
        {:ok, ordered_query} -> {:cont, {:ok, ordered_query}}
        error -> {:halt, error}
      end
    end)
  end

  defp apply_jmap_sort(query, nil), do: {:ok, order_by(query, [m], desc: m.inserted_at)}
  defp apply_jmap_sort(query, []), do: {:ok, order_by(query, [m], desc: m.inserted_at)}
  defp apply_jmap_sort(_query, _), do: {:error, :invalid_sort}

  # Convert Elektrine Message to JMAP Email format
  defp message_to_jmap_email(message, properties) do
    base = %{
      "id" => to_string(message.id),
      "blobId" => message.jmap_blob_id || to_string(message.id),
      "threadId" => to_string(message.thread_id || message.id),
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
        true -> Map.put(ids, "#{base_id}-#{message.category || "inbox"}", true)
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

  defp decrypt_messages_for_mailbox(messages, mailbox_id) when is_list(messages) do
    case Repo.get(Mailbox, mailbox_id) do
      %Mailbox{user_id: user_id} when is_integer(user_id) ->
        Message.decrypt_messages(messages, user_id)

      _ ->
        messages
    end
  end

  defp build_jmap_filter(nil, _mailbox_id), do: {:ok, dynamic(true)}

  defp build_jmap_filter(filter, _mailbox_id) when is_map(filter) and map_size(filter) == 0,
    do: {:ok, dynamic(true)}

  defp build_jmap_filter(%{"operator" => operator, "conditions" => conditions}, mailbox_id)
       when is_list(conditions) do
    with {:ok, condition_dynamics} <- build_condition_dynamics(conditions, mailbox_id) do
      combine_filter_conditions(operator, condition_dynamics)
    end
  end

  defp build_jmap_filter(filter, mailbox_id) when is_map(filter) do
    Enum.reduce_while(filter, {:ok, dynamic(true)}, fn
      {"operator", _}, _acc ->
        {:halt, {:error, :invalid_filter}}

      {"conditions", _}, _acc ->
        {:halt, {:error, :invalid_filter}}

      {key, value}, {:ok, acc} ->
        case build_leaf_filter(key, value, mailbox_id) do
          {:ok, leaf_dynamic} ->
            {:cont, {:ok, dynamic([m], ^acc and ^leaf_dynamic)}}

          error ->
            {:halt, error}
        end
    end)
  end

  defp build_jmap_filter(_filter, _mailbox_id), do: {:error, :invalid_filter}

  defp build_condition_dynamics(conditions, mailbox_id) do
    Enum.reduce_while(conditions, {:ok, []}, fn condition, {:ok, acc} ->
      case build_jmap_filter(condition, mailbox_id) do
        {:ok, filter_dynamic} -> {:cont, {:ok, [filter_dynamic | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp combine_filter_conditions(operator, dynamics) when is_binary(operator) do
    case String.upcase(operator) do
      "AND" ->
        {:ok,
         Enum.reduce(dynamics, dynamic(true), fn item, acc -> dynamic([m], ^acc and ^item) end)}

      "OR" ->
        {:ok,
         Enum.reduce(dynamics, dynamic(false), fn item, acc -> dynamic([m], ^acc or ^item) end)}

      "NOT" ->
        case dynamics do
          [item] -> {:ok, dynamic([m], not (^item))}
          _ -> {:error, :invalid_filter}
        end

      _ ->
        {:error, {:unsupported_filter, "operator:#{operator}"}}
    end
  end

  defp build_leaf_filter("inMailbox", mailbox_jmap_id, _mailbox_id)
       when is_binary(mailbox_jmap_id) do
    mailbox_filter_dynamic(mailbox_jmap_id)
  end

  defp build_leaf_filter("inThread", thread_id, _mailbox_id) do
    case parse_entity_id(thread_id) do
      nil -> {:error, {:unsupported_filter, "inThread"}}
      int_id -> {:ok, dynamic([m], m.thread_id == ^int_id)}
    end
  end

  defp build_leaf_filter("from", from, _mailbox_id) when is_binary(from),
    do: {:ok, dynamic([m], ilike(m.from, ^"%#{from}%"))}

  defp build_leaf_filter("to", to, _mailbox_id) when is_binary(to),
    do: {:ok, dynamic([m], ilike(m.to, ^"%#{to}%"))}

  defp build_leaf_filter("cc", cc, _mailbox_id) when is_binary(cc),
    do: {:ok, dynamic([m], ilike(m.cc, ^"%#{cc}%"))}

  defp build_leaf_filter("bcc", bcc, _mailbox_id) when is_binary(bcc),
    do: {:ok, dynamic([m], ilike(m.bcc, ^"%#{bcc}%"))}

  defp build_leaf_filter("subject", subject, _mailbox_id) when is_binary(subject),
    do: {:ok, dynamic([m], ilike(m.subject, ^"%#{subject}%"))}

  defp build_leaf_filter("hasKeyword", keyword, _mailbox_id),
    do: keyword_filter_dynamic(:has, keyword)

  defp build_leaf_filter("notKeyword", keyword, _mailbox_id),
    do: keyword_filter_dynamic(:not, keyword)

  defp build_leaf_filter("before", datetime, _mailbox_id),
    do: datetime_filter_dynamic(:before, datetime)

  defp build_leaf_filter("after", datetime, _mailbox_id),
    do: datetime_filter_dynamic(:after, datetime)

  defp build_leaf_filter("hasAttachment", value, _mailbox_id) when is_boolean(value),
    do: {:ok, dynamic([m], m.has_attachments == ^value)}

  defp build_leaf_filter(key, _value, _mailbox_id), do: {:error, {:unsupported_filter, key}}

  defp mailbox_filter_dynamic(jmap_mailbox_id) do
    filter_dynamic =
      cond do
        String.ends_with?(jmap_mailbox_id, "-inbox") ->
          dynamic(
            [m],
            m.category == "inbox" and m.deleted == false and m.spam == false and
              m.archived == false and m.status == "received"
          )

        String.ends_with?(jmap_mailbox_id, "-feed") ->
          dynamic([m], m.category == "feed" and m.deleted == false and m.spam == false)

        String.ends_with?(jmap_mailbox_id, "-ledger") ->
          dynamic([m], m.category == "ledger" and m.deleted == false and m.spam == false)

        String.ends_with?(jmap_mailbox_id, "-stack") ->
          dynamic([m], m.category == "stack" and m.deleted == false and m.spam == false)

        String.ends_with?(jmap_mailbox_id, "-sent") ->
          dynamic([m], m.status == "sent" and m.deleted == false)

        String.ends_with?(jmap_mailbox_id, "-drafts") ->
          dynamic([m], m.status == "draft" and m.deleted == false)

        String.ends_with?(jmap_mailbox_id, "-trash") ->
          dynamic([m], m.deleted == true)

        String.ends_with?(jmap_mailbox_id, "-spam") ->
          dynamic([m], m.spam == true and m.deleted == false)

        String.ends_with?(jmap_mailbox_id, "-archive") ->
          dynamic([m], m.archived == true and m.deleted == false and m.spam == false)

        true ->
          nil
      end

    case filter_dynamic do
      nil -> {:error, {:unsupported_filter, "inMailbox"}}
      dynamic -> {:ok, dynamic}
    end
  end

  defp keyword_filter_dynamic(mode, "$seen") do
    comparator = if mode == :has, do: true, else: false
    {:ok, dynamic([m], m.read == ^comparator)}
  end

  defp keyword_filter_dynamic(mode, "$flagged") do
    comparator = if mode == :has, do: true, else: false
    {:ok, dynamic([m], m.flagged == ^comparator)}
  end

  defp keyword_filter_dynamic(mode, "$answered") do
    comparator = if mode == :has, do: true, else: false
    {:ok, dynamic([m], m.answered == ^comparator)}
  end

  defp keyword_filter_dynamic(:has, "$draft"), do: {:ok, dynamic([m], m.status == "draft")}
  defp keyword_filter_dynamic(:not, "$draft"), do: {:ok, dynamic([m], m.status != "draft")}

  defp keyword_filter_dynamic(_mode, keyword),
    do: {:error, {:unsupported_filter, "keyword:#{keyword}"}}

  defp datetime_filter_dynamic(direction, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        case direction do
          :before -> {:ok, dynamic([m], m.inserted_at < ^datetime)}
          :after -> {:ok, dynamic([m], m.inserted_at > ^datetime)}
        end

      _ ->
        {:error, {:invalid_filter_value, value}}
    end
  end

  defp datetime_filter_dynamic(_direction, value), do: {:error, {:invalid_filter_value, value}}

  defp parse_email_state_counter(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [counter, _marker] ->
        with {counter_int, ""} <- Integer.parse(counter) do
          {:ok, counter_int}
        else
          _ -> :error
        end

      [counter] ->
        with {counter_int, ""} <- Integer.parse(counter) do
          {:ok, counter_int}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_email_state_counter(value) when is_integer(value), do: {:ok, value}

  defp parse_email_state_counter(_value), do: :error

  defp record_email_change(mailbox_id, email_id, change_type, extra_entity_types)
       when is_integer(mailbox_id) and is_integer(email_id) and is_list(extra_entity_types) do
    case EmailChange.record(mailbox_id, email_id, change_type, extra_entity_types) do
      {:ok, _change} ->
        broadcast_state_change(mailbox_id, ["Email" | extra_entity_types])
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broadcast_state_change(mailbox_id, entity_types) do
    entity_types =
      entity_types
      |> Enum.filter(&(&1 in @supported_state_types))
      |> Enum.uniq()

    if entity_types != [] do
      Phoenix.PubSub.broadcast(
        PubSub,
        "jmap:#{mailbox_id}",
        {:jmap_state_change, entity_types}
      )
    end
  end

  defp fold_email_changes(changes) do
    changes
    |> Enum.group_by(& &1.email_id)
    |> Enum.reduce({[], [], []}, fn {email_id, email_changes}, {created, updated, destroyed} ->
      change_types = Enum.map(email_changes, & &1.change_type)
      last_type = List.last(change_types)

      cond do
        "created" in change_types and last_type == "destroyed" ->
          {created, updated, destroyed}

        "created" in change_types ->
          {[email_id | created], updated, destroyed}

        last_type == "destroyed" ->
          {created, updated, [email_id | destroyed]}

        true ->
          {created, [email_id | updated], destroyed}
      end
    end)
    |> then(fn {created, updated, destroyed} ->
      {Enum.sort(created), Enum.sort(updated), Enum.sort(destroyed)}
    end)
  end

  defp parse_entity_id(id) when is_integer(id), do: id

  defp parse_entity_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> int_id
      _ -> nil
    end
  end

  defp parse_entity_id(_id), do: nil
end
