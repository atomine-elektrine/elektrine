defmodule Elektrine.Social.HashtagExtractor do
  @moduledoc """
  Extracts hashtags from text content and manages hashtag associations.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo
  alias Elektrine.Social.{Hashtag, PostHashtag}

  @doc """
  Extracts hashtags from text content.
  """
  def extract_hashtags(content) do
    # Regex to match hashtags: # followed by word characters
    hashtag_regex = ~r/#(\w+)/

    Regex.scan(hashtag_regex, content)
    # Get the captured group (without #)
    |> Enum.map(&List.last/1)
    |> Enum.uniq()
    |> Enum.filter(&valid_hashtag?/1)
  end

  @doc """
  Creates or updates hashtags and associates them with a message.
  """
  def process_hashtags_for_message(message_id, hashtags) when is_list(hashtags) do
    Enum.each(hashtags, fn hashtag_name ->
      hashtag = get_or_create_hashtag(hashtag_name)
      create_post_hashtag_association(message_id, hashtag.id)
      increment_hashtag_usage(hashtag.id)
    end)
  end

  @doc """
  Gets posts for a specific hashtag (includes local and federated posts).
  """
  def get_posts_for_hashtag(hashtag_name, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    before_id = Keyword.get(opts, :before_id)
    preloads = Elektrine.Messaging.Messages.timeline_post_preloads()

    normalized_name = String.downcase(hashtag_name)

    query =
      from m in Message,
        join: ph in PostHashtag,
        on: ph.message_id == m.id,
        join: h in Hashtag,
        on: h.id == ph.hashtag_id,
        where:
          h.normalized_name == ^normalized_name and
            m.visibility in ["public", "followers", "unlisted"] and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)) and
            (not is_nil(m.sender_id) or not is_nil(m.remote_actor_id)),
        order_by: [desc: m.id],
        limit: ^limit

    # Reuse standard timeline preloads so hashtag cards match timeline/detail rendering.
    query =
      from m in query,
        preload: ^preloads

    query =
      if before_id do
        from m in query, where: m.id < ^before_id
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Gets trending hashtags based on recent usage.
  """
  def get_trending_hashtags(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    days_back = Keyword.get(opts, :days_back, 7)

    cutoff_date = DateTime.utc_now() |> DateTime.add(-days_back, :day)

    from(h in Hashtag,
      where: h.last_used_at > ^cutoff_date,
      order_by: [desc: h.use_count, desc: h.last_used_at],
      limit: ^limit,
      select: %{
        name: h.name,
        normalized_name: h.normalized_name,
        use_count: h.use_count,
        last_used_at: h.last_used_at
      }
    )
    |> Repo.all()
  end

  @doc """
  Searches hashtags by name.
  """
  def search_hashtags(query, limit \\ 10) do
    search_term = "%#{String.downcase(query)}%"

    from(h in Hashtag,
      where: ilike(h.normalized_name, ^search_term),
      order_by: [desc: h.use_count],
      limit: ^limit,
      select: %{
        name: h.name,
        normalized_name: h.normalized_name,
        use_count: h.use_count
      }
    )
    |> Repo.all()
  end

  # Private functions

  defp valid_hashtag?(hashtag) do
    # Basic validation: length between 1-50 chars, alphanumeric + underscore
    String.length(hashtag) >= 1 and
      String.length(hashtag) <= 50 and
      Regex.match?(~r/^[a-zA-Z0-9_]+$/, hashtag)
  end

  defp get_or_create_hashtag(name) do
    normalized_name = String.downcase(name)

    case Repo.get_by(Hashtag, normalized_name: normalized_name) do
      nil ->
        # Create new hashtag
        case %Hashtag{}
             |> Hashtag.changeset(%{
               name: name,
               normalized_name: normalized_name,
               use_count: 0,
               last_used_at: DateTime.utc_now()
             })
             |> Repo.insert() do
          {:ok, hashtag} ->
            hashtag

          {:error, _} ->
            # Race condition - try to get existing
            Repo.get_by(Hashtag, normalized_name: normalized_name)
        end

      hashtag ->
        hashtag
    end
  end

  defp create_post_hashtag_association(message_id, hashtag_id) do
    %PostHashtag{}
    |> PostHashtag.changeset(%{
      message_id: message_id,
      hashtag_id: hashtag_id
    })
    |> Repo.insert()
  end

  defp increment_hashtag_usage(hashtag_id) do
    from(h in Hashtag, where: h.id == ^hashtag_id)
    |> Repo.update_all(
      inc: [use_count: 1],
      set: [last_used_at: DateTime.utc_now()]
    )
  end
end
