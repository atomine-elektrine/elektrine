defmodule Elektrine.Search.Cached do
  @moduledoc """
  Cached search functionality for emails and other data.
  Provides fast access to search results and recent searches.
  """

  alias Elektrine.AppCache
  alias Elektrine.Email

  @doc """
  Performs cached email search with pagination.
  """
  def search_messages(user_id, mailbox_id, query, page \\ 1, per_page \\ 20) do
    case AppCache.get_search_results(user_id, query, page, per_page, fn ->
           # This would need to be implemented in Email context
           # Run a lightweight local search until Email-backed search is integrated.
           perform_email_search(mailbox_id, query, page, per_page)
         end) do
      {:ok, results} ->
        # Update recent searches in background
        Task.start(fn ->
          add_to_recent_searches(user_id, query)
        end)

        results

      {:error, _reason} ->
        # Fallback to direct search if cache fails
        perform_email_search(mailbox_id, query, page, per_page)
    end
  end

  @doc """
  Gets cached recent searches for a user.
  """
  def get_recent_searches(user_id) do
    case AppCache.get_recent_searches(user_id, fn ->
           # This would load from database or return empty list
           []
         end) do
      {:ok, searches} -> searches
      {:error, _reason} -> []
    end
  end

  @doc """
  Gets cached popular search terms (system-wide).
  """
  def get_popular_searches do
    case AppCache.get_system_config("popular_searches", fn ->
           # This would aggregate popular searches from all users
           ["receipt", "invoice", "newsletter", "notification", "security"]
         end) do
      {:ok, searches} -> searches
      {:error, _reason} -> ["receipt", "invoice", "newsletter", "notification", "security"]
    end
  end

  @doc """
  Invalidates search cache for a user.
  """
  def invalidate_search_cache(user_id) do
    AppCache.invalidate_search_cache(user_id)
  end

  @doc """
  Invalidates all search caches (when search index changes).
  """
  def invalidate_all_search_caches do
    # This would be called when email content changes significantly
    AppCache.clear_by_pattern({:search, :_, :_, :_, :_})
  end

  # Private functions

  defp perform_email_search(mailbox_id, query, page, per_page) do
    # Simulate search - in real implementation this would:
    # 1. Use full-text search on email content
    # 2. Search across subject, body, sender, etc.
    # 3. Apply ranking/relevance scoring
    # 4. Return paginated results

    offset = (page - 1) * per_page

    # Use simple subject/sender matching for the fallback search path.
    messages =
      Email.list_messages(mailbox_id, per_page * 2, 0)
      |> Enum.filter(fn message ->
        query_lower = String.downcase(query)

        subject_match =
          case message.subject do
            nil -> false
            "" -> false
            subject -> subject |> String.downcase() |> String.contains?(query_lower)
          end

        sender_match =
          case message.from do
            nil -> false
            "" -> false
            from -> from |> String.downcase() |> String.contains?(query_lower)
          end

        subject_match or sender_match
      end)
      |> Enum.drop(offset)
      |> Enum.take(per_page)

    total_count = length(messages)
    total_pages = ceil(total_count / per_page)

    %{
      messages: messages,
      page: page,
      per_page: per_page,
      total_count: total_count,
      total_pages: total_pages,
      has_next: page < total_pages,
      has_prev: page > 1,
      query: query
    }
  end

  defp add_to_recent_searches(user_id, query) do
    # Add query to user's recent searches
    recent = get_recent_searches(user_id)

    # Remove query if it already exists, then add to front
    updated_recent =
      [query | Enum.reject(recent, &(&1 == query))]
      # Keep only last 10 searches
      |> Enum.take(10)

    # This would save to database in real implementation
    case AppCache.get_recent_searches(user_id, fn -> updated_recent end) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end
end
