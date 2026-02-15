defmodule Elektrine.Email.Folders do
  @moduledoc """
  Folder and category management for email messages.
  Handles Hey.com-style categories (Feed, Ledger, Stack) and folder operations.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.Email.{Message, Mailbox, CacheHooks}

  # Private helper to decrypt email messages and preload labels
  defp decrypt_email_messages(messages, mailbox_id) when is_list(messages) do
    # Preload labels for all messages
    messages = Repo.preload(messages, :labels)

    case Elektrine.Email.Mailboxes.get_mailbox(mailbox_id) do
      %Mailbox{user_id: user_id} when not is_nil(user_id) ->
        Message.decrypt_messages(messages, user_id)

      _ ->
        messages
    end
  end

  ## Paginated List Functions

  @doc """
  Returns paginated messages for a mailbox with metadata.
  """
  def list_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Get total count
    total_count =
      Message
      |> where(mailbox_id: ^mailbox_id)
      |> Repo.aggregate(:count)

    # Get messages for current page
    messages = Elektrine.Email.Messages.list_messages(mailbox_id, per_page, offset)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  @doc """
  Returns paginated inbox messages (non-spam, non-archived, non-bulk, non-paper-trail) for a mailbox with metadata.
  Optimized to build base query once and reuse for both count and fetch.
  """
  def list_inbox_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Build base query once with common filters
    base_query =
      Message
      |> where(mailbox_id: ^mailbox_id, spam: false, archived: false, deleted: false)
      |> where(
        [m],
        (m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to) and
          m.category not in ["feed", "ledger", "stack"] and is_nil(m.reply_later_at) and
          is_nil(m.folder_id)
      )

    # Get total count (optimized - single AND clause)
    total_count = Repo.aggregate(base_query, :count)

    # Get messages for current page (reuse base query)
    messages =
      base_query
      |> order_by(desc: :inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> decrypt_email_messages(mailbox_id)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  @doc """
  Returns paginated spam messages for a mailbox with metadata.
  """
  def list_spam_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Get total count
    total_count =
      Message
      |> where(mailbox_id: ^mailbox_id, spam: true, archived: false, deleted: false)
      |> where([m], is_nil(m.folder_id))
      |> Repo.aggregate(:count)

    # Get messages for current page
    messages = Elektrine.Email.Messages.list_spam_messages(mailbox_id, per_page, offset)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  @doc """
  Returns paginated trash messages for a mailbox with metadata.
  """
  def list_trash_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Get total count - trash shows ALL deleted messages regardless of other filters
    total_count =
      Message
      |> where(mailbox_id: ^mailbox_id, deleted: true)
      |> Repo.aggregate(:count)

    # Get messages for current page - trash shows ALL deleted messages
    messages =
      Message
      |> where(mailbox_id: ^mailbox_id, deleted: true)
      |> order_by(desc: :inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> decrypt_email_messages(mailbox_id)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  @doc """
  Returns paginated archived messages for a mailbox with metadata.
  """
  def list_archived_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Get total count
    total_count =
      Message
      |> where(mailbox_id: ^mailbox_id, archived: true, deleted: false)
      |> where([m], is_nil(m.folder_id))
      |> Repo.aggregate(:count)

    # Get messages for current page
    messages = Elektrine.Email.Messages.list_archived_messages(mailbox_id, per_page, offset)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  @doc """
  Returns paginated sent messages for a mailbox with metadata.
  """
  def list_sent_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Get total count
    total_count =
      Message
      |> where([m], m.mailbox_id == ^mailbox_id)
      |> where([m], m.status == "sent")
      |> where([m], not m.archived)
      |> where([m], not m.deleted)
      |> where([m], is_nil(m.folder_id))
      |> Repo.aggregate(:count)

    # Get messages for current page
    messages =
      Message
      |> where([m], m.mailbox_id == ^mailbox_id)
      |> where([m], m.status == "sent")
      |> where([m], not m.archived)
      |> where([m], not m.deleted)
      |> where([m], is_nil(m.folder_id))
      |> order_by(desc: :inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> decrypt_email_messages(mailbox_id)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  @doc """
  Returns paginated draft messages for a mailbox with metadata.
  """
  def list_drafts_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Build base query for drafts
    base_query =
      Message
      |> where([m], m.mailbox_id == ^mailbox_id)
      |> where([m], m.status == "draft")
      |> where([m], not m.deleted)
      |> where([m], is_nil(m.folder_id))

    # Get total count
    total_count = Repo.aggregate(base_query, :count)

    # Get messages for current page
    messages =
      base_query
      |> order_by(desc: :updated_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> decrypt_email_messages(mailbox_id)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  @doc """
  Returns the count of draft messages for a mailbox.
  """
  def drafts_count(mailbox_id) do
    Message
    |> where([m], m.mailbox_id == ^mailbox_id)
    |> where([m], m.status == "draft")
    |> where([m], not m.deleted)
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns paginated unread messages for a mailbox with metadata.
  Optimized to build base query once and reuse for both count and fetch.
  """
  def list_unread_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Build base query once with common filters
    base_query =
      Message
      |> where(mailbox_id: ^mailbox_id, read: false)
      |> where([m], not m.spam and not m.archived and not m.deleted)
      |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
      |> where([m], m.category not in ["feed", "ledger", "stack"])
      |> where([m], is_nil(m.reply_later_at))
      |> where([m], is_nil(m.folder_id))

    # Get total count (optimized - single AND clause)
    total_count = Repo.aggregate(base_query, :count)

    # Get messages for current page (reuse base query)
    messages =
      base_query
      |> order_by(desc: :inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> decrypt_email_messages(mailbox_id)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  @doc """
  Returns paginated read messages for a mailbox with metadata.
  Optimized to build base query once and reuse for both count and fetch.
  """
  def list_read_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Build base query once with common filters
    base_query =
      Message
      |> where(mailbox_id: ^mailbox_id, read: true)
      |> where([m], not m.spam and not m.archived and not m.deleted)
      |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
      |> where([m], m.category not in ["feed", "ledger", "stack"])
      |> where([m], is_nil(m.reply_later_at))
      |> where([m], is_nil(m.folder_id))

    # Get total count (optimized - single AND clause)
    total_count = Repo.aggregate(base_query, :count)

    # Get messages for current page (reuse base query)
    messages =
      base_query
      |> order_by(desc: :inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> decrypt_email_messages(mailbox_id)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  ## Hey.com-style Features

  @doc """
  Returns messages in The Feed (newsletters, notifications).
  """
  def list_feed_messages(mailbox_id, limit \\ 50, offset \\ 0) do
    Message
    |> where(mailbox_id: ^mailbox_id)
    |> where(category: "feed")
    |> where([m], not m.spam)
    |> where([m], not m.archived)
    |> where([m], not m.deleted)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns paginated feed messages for a mailbox with metadata.
  Optimized to build base query once and reuse for both count and fetch.
  """
  def list_feed_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Build base query once with common filters
    base_query =
      Message
      |> where(mailbox_id: ^mailbox_id)
      |> where(category: "feed")
      |> where([m], not m.spam and not m.archived and not m.deleted)
      |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)

    # Get total count (optimized - single AND clause)
    total_count = Repo.aggregate(base_query, :count)

    # Get messages for current page (reuse base query)
    messages =
      base_query
      |> order_by(desc: :inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> decrypt_email_messages(mailbox_id)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  @doc """
  Returns messages in Paper Trail (receipts, confirmations).
  """
  def list_ledger_messages(mailbox_id, limit \\ 50, offset \\ 0) do
    Message
    |> where(mailbox_id: ^mailbox_id)
    |> where(category: "ledger")
    |> where([m], not m.spam)
    |> where([m], not m.archived)
    |> where([m], not m.deleted)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns paginated paper trail messages for a mailbox with metadata.
  Optimized to build base query once and reuse for both count and fetch.
  """
  def list_ledger_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Build base query once with common filters
    base_query =
      Message
      |> where(mailbox_id: ^mailbox_id)
      |> where(category: "ledger")
      |> where([m], not m.spam and not m.archived and not m.deleted)
      |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)

    # Get total count (optimized - single AND clause)
    total_count = Repo.aggregate(base_query, :count)

    # Get messages for current page (reuse base query)
    messages =
      base_query
      |> order_by(desc: :inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> decrypt_email_messages(mailbox_id)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  @doc """
  Returns messages that are set aside.
  """
  def list_stack_messages(mailbox_id, limit \\ 50, offset \\ 0) do
    Message
    |> where(mailbox_id: ^mailbox_id)
    |> where(category: "stack")
    |> where([m], not is_nil(m.stack_at))
    |> where([m], not m.spam)
    |> where([m], not m.archived)
    |> where([m], not m.deleted)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
    |> order_by(desc: :stack_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns paginated set aside messages for a mailbox with metadata.
  Optimized to build base query once and reuse for both count and fetch.
  """
  def list_stack_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Build base query once with common filters
    base_query =
      Message
      |> where(mailbox_id: ^mailbox_id)
      |> where(category: "stack")
      |> where([m], not is_nil(m.stack_at) and not m.spam and not m.archived and not m.deleted)
      |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)

    # Get total count (optimized - single AND clause)
    total_count = Repo.aggregate(base_query, :count)

    # Get messages for current page (reuse base query)
    messages =
      base_query
      |> order_by(desc: :stack_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> decrypt_email_messages(mailbox_id)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  @doc """
  Returns messages marked for reply later.
  """
  def list_reply_later_messages(mailbox_id, limit \\ 50, offset \\ 0) do
    Message
    |> where(mailbox_id: ^mailbox_id)
    |> where([m], not is_nil(m.reply_later_at))
    |> where([m], not m.spam)
    |> where([m], not m.archived)
    |> where([m], not m.deleted)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
    |> order_by(:reply_later_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns paginated reply later messages for a mailbox with metadata.
  Optimized to build base query once and reuse for both count and fetch.
  """
  def list_reply_later_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    page = max(page, 1)
    offset = (page - 1) * per_page

    # Build base query once with common filters
    base_query =
      Message
      |> where(mailbox_id: ^mailbox_id)
      |> where(
        [m],
        not is_nil(m.reply_later_at) and not m.spam and not m.archived and not m.deleted
      )
      |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)

    # Get total count (optimized - single AND clause)
    total_count = Repo.aggregate(base_query, :count)

    # Get messages for current page (reuse base query)
    messages =
      base_query
      |> order_by(:reply_later_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> decrypt_email_messages(mailbox_id)

    # Calculate pagination metadata
    total_pages = ceil(total_count / per_page)
    has_next = page < total_pages
    has_prev = page > 1

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: has_next,
      has_prev: has_prev
    }
  end

  ## Bulk List Functions (no pagination)

  @doc """
  Returns all inbox messages for a mailbox without pagination.
  Used for bulk operations.
  """
  def list_all_inbox_messages(mailbox_id) do
    Message
    |> where(mailbox_id: ^mailbox_id, spam: false, archived: false, deleted: false)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
    |> where([m], m.category not in ["feed", "ledger", "stack"])
    |> where([m], is_nil(m.reply_later_at))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns all feed messages (bulk mail) for a mailbox without pagination.
  """
  def list_all_feed_messages(mailbox_id) do
    Message
    |> where(mailbox_id: ^mailbox_id)
    |> where(category: "feed")
    |> where([m], not m.spam)
    |> where([m], not m.archived)
    |> where([m], not m.deleted)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns all paper trail messages for a mailbox without pagination.
  """
  def list_all_ledger_messages(mailbox_id) do
    Message
    |> where(mailbox_id: ^mailbox_id)
    |> where(category: "ledger")
    |> where([m], not m.spam)
    |> where([m], not m.archived)
    |> where([m], not m.deleted)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns all set aside messages for a mailbox without pagination.
  """
  def list_all_stack_messages(mailbox_id) do
    Message
    |> where(mailbox_id: ^mailbox_id)
    |> where(category: "stack")
    |> where([m], not m.spam)
    |> where([m], not m.archived)
    |> where([m], not m.deleted)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns all reply later messages for a mailbox without pagination.
  """
  def list_all_reply_later_messages(mailbox_id) do
    Message
    |> where(mailbox_id: ^mailbox_id)
    |> where([m], not is_nil(m.reply_later_at))
    |> where([m], not m.spam)
    |> where([m], not m.archived)
    |> where([m], not m.deleted)
    |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns all sent messages for a mailbox without pagination.
  """
  def list_all_sent_messages(mailbox_id) do
    Message
    |> where([m], m.mailbox_id == ^mailbox_id)
    |> where([m], m.status == "sent")
    |> where([m], not m.archived)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  @doc """
  Returns all spam messages for a mailbox without pagination.
  """
  def list_all_spam_messages(mailbox_id) do
    Message
    |> where(mailbox_id: ^mailbox_id, spam: true, archived: false)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> decrypt_email_messages(mailbox_id)
  end

  ## Category Movement Operations

  @doc """
  Sets aside a message for later processing.
  """
  def stack_message(%Message{} = message, reason \\ nil) do
    message
    |> Message.stack_changeset(%{stack_reason: reason})
    |> Repo.update()
    |> CacheHooks.with_cache_invalidation()
  end

  @doc """
  Removes a message from set aside.
  """
  def unstack_message(%Message{} = message) do
    message
    |> Message.unstack_changeset()
    |> Repo.update()
    |> CacheHooks.with_cache_invalidation()
  end

  @doc """
  Moves a message to digest category.
  """
  def move_to_digest(%Message{} = message) do
    message
    |> Message.changeset(%{category: "feed"})
    |> Repo.update()
    |> CacheHooks.with_cache_invalidation()
  end

  @doc """
  Moves a message to ledger category.
  """
  def move_to_ledger(%Message{} = message) do
    message
    |> Message.changeset(%{category: "ledger"})
    |> Repo.update()
    |> CacheHooks.with_cache_invalidation()
  end

  @doc """
  Sets a message for reply later.
  """
  def reply_later_message(%Message{} = message, reply_at, reminder \\ false) do
    message
    |> Message.reply_later_changeset(%{
      reply_later_at: reply_at,
      reply_later_reminder: reminder
    })
    |> Repo.update()
    |> CacheHooks.with_cache_invalidation()
  end

  @doc """
  Clears reply later for a message.
  """
  def clear_reply_later(%Message{} = message) do
    message
    |> Message.clear_reply_later_changeset()
    |> Repo.update()
    |> CacheHooks.with_cache_invalidation()
  end

  ## IMAP Folder Operations

  @doc """
  Lists messages for IMAP access by folder.
  Returns messages with necessary fields for IMAP protocol.
  """
  def list_messages_for_imap(mailbox_id, folder) when is_integer(mailbox_id) do
    base_query =
      Message
      |> where([m], m.mailbox_id == ^mailbox_id)
      |> where([m], is_nil(m.reply_later_at))

    query =
      case folder do
        :inbox ->
          # Match webmail: show everything except sent/drafts, spam, deleted, archived
          base_query
          |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status) or m.from == m.to)
          |> where([m], not m.spam)
          |> where([m], not m.deleted)
          |> where([m], not m.archived)

        :sent ->
          base_query
          |> where([m], m.status == "sent")
          |> where([m], not m.deleted)

        :drafts ->
          base_query
          |> where([m], m.status == "draft")
          |> where([m], not m.deleted)

        :trash ->
          # Trash should show ALL deleted messages, even boomerang ones
          Message
          |> where([m], m.mailbox_id == ^mailbox_id)
          |> where([m], m.deleted == true)

        :spam ->
          base_query
          |> where([m], m.spam == true and m.status not in ["sent", "draft"])
          |> where([m], not m.deleted)

        _ ->
          base_query
          |> where([m], not m.spam and not m.archived)
          |> where([m], m.status not in ["sent", "draft"] or is_nil(m.status))
      end

    query
    |> order_by([m], asc: m.id)
    |> select([m], %{
      id: m.id,
      message_id: m.message_id,
      from: m.from,
      to: m.to,
      subject: m.subject,
      read: m.read,
      flagged: m.flagged,
      deleted: m.deleted,
      spam: m.spam,
      answered: m.answered,
      status: m.status,
      inserted_at: m.inserted_at,
      has_attachments: m.has_attachments
    })
    |> Repo.all()
  end

  @doc """
  Lists messages for IMAP access from a custom folder.
  """
  def list_messages_for_imap_custom_folder(mailbox_id, folder_id)
      when is_integer(mailbox_id) and is_integer(folder_id) do
    Message
    |> where([m], m.mailbox_id == ^mailbox_id)
    |> where([m], m.folder_id == ^folder_id)
    |> where([m], is_nil(m.reply_later_at))
    |> where([m], not m.deleted)
    |> order_by([m], asc: m.id)
    |> select([m], %{
      id: m.id,
      message_id: m.message_id,
      from: m.from,
      to: m.to,
      subject: m.subject,
      read: m.read,
      flagged: m.flagged,
      deleted: m.deleted,
      spam: m.spam,
      answered: m.answered,
      status: m.status,
      inserted_at: m.inserted_at,
      has_attachments: m.has_attachments
    })
    |> Repo.all()
  end

  @doc """
  Lists messages for POP3 access.
  Returns messages with necessary fields for POP3 protocol.
  """
  def list_messages_for_pop3(mailbox_id) when is_integer(mailbox_id) do
    # Load full message structs so we can decrypt them
    messages =
      Message
      |> where([m], m.mailbox_id == ^mailbox_id)
      |> where([m], not m.spam and not m.archived)
      |> where([m], m.status != "sent" or is_nil(m.status))
      |> where([m], is_nil(m.reply_later_at))
      |> order_by(asc: :inserted_at)
      |> Repo.all()
      |> decrypt_email_messages(mailbox_id)

    # Convert to the format expected by POP3
    Enum.map(messages, fn m ->
      %{
        id: m.id,
        message_id: m.message_id,
        from: m.from,
        to: m.to,
        subject: m.subject,
        text_body: m.text_body,
        html_body: m.html_body,
        inserted_at: m.inserted_at,
        attachments: m.attachments,
        has_attachments: m.has_attachments
      }
    end)
  end
end
