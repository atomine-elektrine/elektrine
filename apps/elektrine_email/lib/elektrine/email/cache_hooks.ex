defmodule Elektrine.Email.CacheHooks do
  @moduledoc """
  Helper module to add cache invalidation hooks to Email context functions.
  This module provides wrapper functions that invalidate relevant caches
  when email data is modified.
  """

  alias Elektrine.Email
  alias Elektrine.Email.Cached

  @doc """
  Adds cache invalidation to the result of an Email operation.
  """
  def with_cache_invalidation(result, opts \\ [])

  def with_cache_invalidation({:ok, message} = result, opts) when is_map(message) do
    mailbox_id = message.mailbox_id || opts[:mailbox_id]
    user_id = opts[:user_id] || get_user_id_from_mailbox(mailbox_id)
    categories = opts[:categories] || [:all]

    if mailbox_id && user_id do
      Cached.invalidate_message_caches(mailbox_id, user_id, categories)
    end

    result
  end

  def with_cache_invalidation({:error, _} = result, _opts), do: result
  def with_cache_invalidation(result, _opts), do: result

  @doc """
  Gets user_id from mailbox_id
  """
  def get_user_id_from_mailbox(mailbox_id) when is_binary(mailbox_id) or is_integer(mailbox_id) do
    case Email.get_mailbox_internal(mailbox_id) do
      nil -> nil
      mailbox -> mailbox.user_id
    end
  end

  def get_user_id_from_mailbox(_), do: nil

  @doc """
  Invalidates caches for multiple messages
  """
  def invalidate_for_messages(messages) when is_list(messages) do
    messages
    |> Enum.group_by(& &1.mailbox_id)
    |> Enum.each(fn {mailbox_id, _msgs} ->
      user_id = get_user_id_from_mailbox(mailbox_id)
      if user_id, do: Cached.invalidate_message_caches(mailbox_id, user_id)
    end)
  end

  @doc """
  Determines which cache categories should be invalidated based on the message
  """
  def affected_categories(message) do
    categories = [:inbox]

    categories = if message.category == "feed", do: [:feed | categories], else: categories

    categories =
      if message.category == "ledger", do: [:ledger | categories], else: categories

    categories =
      if message.category == "stack", do: [:stack | categories], else: categories

    categories = if message.reply_later_at, do: [:reply_later | categories], else: categories

    Enum.uniq(categories)
  end
end
