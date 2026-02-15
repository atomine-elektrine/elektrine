defmodule Elektrine.Email.Cached do
  @moduledoc """
  Cached versions of Email context functions.
  This module provides cached wrappers around frequently-accessed Email functions
  to improve performance and reduce database load.
  """

  alias Elektrine.Email
  alias Elektrine.Email.Cache
  alias Elektrine.AppCache

  @doc """
  Gets cached unread count for a mailbox.
  """
  def unread_count(mailbox_id) do
    {:ok, count} =
      Cache.get_counts("mailbox:#{mailbox_id}:unread", fn ->
        Email.unread_count(mailbox_id)
      end)

    count
  end

  @doc """
  Gets cached unread count for a user.
  """
  def user_unread_count(user_id) do
    {:ok, count} =
      Cache.get_counts("user:#{user_id}:unread", fn ->
        Email.user_unread_count(user_id)
      end)

    count
  end

  @doc """
  Gets cached paginated messages with automatic cache invalidation.
  """
  def list_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    {:ok, result} =
      Cache.get_messages(mailbox_id, :all, page, per_page, fn ->
        Email.list_messages_paginated(mailbox_id, page, per_page)
      end)

    result
  end

  @doc """
  Gets cached inbox messages paginated.
  """
  def list_inbox_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    {:ok, result} =
      Cache.get_messages(mailbox_id, :inbox, page, per_page, fn ->
        Email.list_inbox_messages_paginated(mailbox_id, page, per_page)
      end)

    result
  end

  @doc """
  Gets cached feed messages paginated.
  """
  def list_feed_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    {:ok, result} =
      Cache.get_messages(mailbox_id, :feed, page, per_page, fn ->
        Email.list_feed_messages_paginated(mailbox_id, page, per_page)
      end)

    result
  end

  @doc """
  Gets cached ledger messages paginated.
  """
  def list_ledger_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    {:ok, result} =
      Cache.get_messages(mailbox_id, :ledger, page, per_page, fn ->
        Email.list_ledger_messages_paginated(mailbox_id, page, per_page)
      end)

    result
  end

  @doc """
  Gets cached stack messages paginated.
  """
  def list_stack_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    {:ok, result} =
      Cache.get_messages(mailbox_id, :stack, page, per_page, fn ->
        Email.list_stack_messages_paginated(mailbox_id, page, per_page)
      end)

    result
  end

  @doc """
  Gets cached reply later messages paginated.
  """
  def list_reply_later_messages_paginated(mailbox_id, page \\ 1, per_page \\ 20) do
    {:ok, result} =
      Cache.get_messages(mailbox_id, :reply_later, page, per_page, fn ->
        Email.list_reply_later_messages_paginated(mailbox_id, page, per_page)
      end)

    result
  end

  @doc """
  Gets cached feed messages count.
  """
  def feed_messages_count(mailbox_id) do
    {:ok, count} =
      Cache.get_counts("mailbox:#{mailbox_id}:feed", fn ->
        Email.list_feed_messages(mailbox_id) |> length()
      end)

    count
  end

  @doc """
  Gets cached ledger messages count.
  """
  def ledger_messages_count(mailbox_id) do
    {:ok, count} =
      Cache.get_counts("mailbox:#{mailbox_id}:ledger", fn ->
        Email.list_ledger_messages(mailbox_id) |> length()
      end)

    count
  end

  @doc """
  Gets all unread counts for a mailbox in a single cached query.
  This ensures consistency by fetching all counts from the same database snapshot.

  Returns a map with keys: :inbox, :feed, :ledger, :stack, :reply_later
  """
  def get_all_unread_counts(mailbox_id) do
    {:ok, counts} =
      Cache.get_counts("mailbox:#{mailbox_id}:all_unread_counts", fn ->
        Email.get_all_unread_counts(mailbox_id)
      end)

    counts
  end

  @doc """
  Gets cached unread feed messages count.
  """
  def unread_feed_count(mailbox_id) do
    get_all_unread_counts(mailbox_id).feed
  end

  @doc """
  Gets cached unread ledger messages count.
  """
  def unread_ledger_count(mailbox_id) do
    get_all_unread_counts(mailbox_id).ledger
  end

  @doc """
  Gets cached unread stack count for a mailbox.
  """
  def unread_stack_count(mailbox_id) do
    get_all_unread_counts(mailbox_id).stack
  end

  @doc """
  Gets cached unread reply later count for a mailbox.
  """
  def unread_reply_later_count(mailbox_id) do
    get_all_unread_counts(mailbox_id).reply_later
  end

  @doc """
  Gets cached unread inbox count for a mailbox.
  """
  def unread_inbox_count(mailbox_id) do
    get_all_unread_counts(mailbox_id).inbox
  end

  @doc """
  Invalidates caches when a message is created, updated, or deleted.
  Should be called from Email context functions that modify messages.
  """
  def invalidate_message_caches(mailbox_id, user_id, categories \\ [:all]) do
    # Invalidate counts
    Cache.invalidate_counts("mailbox:#{mailbox_id}:unread")
    Cache.invalidate_counts("user:#{user_id}:unread")
    Cache.invalidate_counts("mailbox:#{mailbox_id}:digest")
    Cache.invalidate_counts("mailbox:#{mailbox_id}:ledger")
    Cache.invalidate_counts("mailbox:#{mailbox_id}:unread_digest")
    Cache.invalidate_counts("mailbox:#{mailbox_id}:unread_ledger")
    Cache.invalidate_counts("mailbox:#{mailbox_id}:unread_inbox")
    Cache.invalidate_counts("mailbox:#{mailbox_id}:unread_stack")
    Cache.invalidate_counts("mailbox:#{mailbox_id}:unread_reply_later")
    Cache.invalidate_counts("mailbox:#{mailbox_id}:all_unread_counts")

    # Invalidate message lists
    if categories == [:all] do
      Cache.invalidate_messages(mailbox_id, :all)
    else
      Enum.each(categories, fn category ->
        Cache.invalidate_messages(mailbox_id, category)
      end)
    end

    # Also clear search results as they might be affected
    Cache.invalidate_search_results(user_id)
  end

  # Alias management

  @doc """
  Gets cached aliases for a user.
  """
  def get_aliases(user_id) do
    {:ok, aliases} =
      AppCache.get_aliases(user_id, fn ->
        Email.list_aliases(user_id)
      end)

    aliases
  end

  @doc """
  Invalidates cached aliases for a user.
  """
  def invalidate_aliases(user_id) do
    AppCache.invalidate_aliases(user_id)
  end

  @doc """
  Gets cached mailbox settings.
  """
  def get_mailbox_settings(mailbox_id) do
    {:ok, settings} =
      AppCache.get_mailbox_settings(mailbox_id, fn ->
        Email.get_mailbox_internal(mailbox_id)
      end)

    settings
  end

  @doc """
  Warms up cache for a user after login.
  """
  def warm_user_cache(user_id, mailbox_id) do
    # Use the AppCache warming function which is more comprehensive
    AppCache.warm_user_cache(user_id, mailbox_id)

    # Also warm email-specific data
    Task.start(fn ->
      # Load counts
      unread_count(mailbox_id)
      feed_messages_count(mailbox_id)
      ledger_messages_count(mailbox_id)

      # Load first page of inbox
      list_inbox_messages_paginated(mailbox_id, 1, 20)
    end)
  end
end
