defmodule Elektrine.Social.Hashtags do
  @moduledoc """
  Hashtag records: creation, usage counters, and hashtag post collections.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.Repo
  alias Elektrine.Social.Conversation
  alias Elektrine.Social.Hashtag
  alias Elektrine.Social.Message

  @doc """
  Gets or creates a hashtag by name.
  """
  def get_or_create_hashtag(name) do
    normalized_name = String.downcase(name)

    case first_hashtag_by_normalized_name(normalized_name) do
      nil ->
        case %Hashtag{}
             |> Hashtag.changeset(%{
               name: name,
               normalized_name: normalized_name,
               use_count: 0,
               last_used_at: DateTime.utc_now()
             })
             |> Repo.insert(
               on_conflict: :nothing,
               conflict_target: :normalized_name,
               returning: true
             ) do
          {:ok, hashtag} ->
            if hashtag.id, do: hashtag, else: first_hashtag_by_normalized_name(normalized_name)

          {:error, _} ->
            first_hashtag_by_normalized_name(normalized_name)
        end

      hashtag ->
        hashtag
    end
  end

  @doc """
  Increments the usage count for a hashtag.
  """
  def increment_hashtag_usage(hashtag_id) do
    from(h in Hashtag, where: h.id == ^hashtag_id)
    |> Repo.update_all(
      inc: [use_count: 1],
      set: [last_used_at: Elektrine.Time.utc_now()]
    )
  end

  @doc """
  Decrements the usage count for a hashtag without letting it go negative.
  """
  def decrement_hashtag_usage(hashtag_id) do
    case Repo.get(Hashtag, hashtag_id) do
      %Hashtag{use_count: count} when count > 0 ->
        from(h in Hashtag, where: h.id == ^hashtag_id)
        |> Repo.update_all(
          inc: [use_count: -1],
          set: [last_used_at: Elektrine.Time.utc_now()]
        )

      _ ->
        {0, nil}
    end
  end

  @doc """
  Gets a hashtag by its normalized name.
  """
  def get_hashtag_by_normalized_name(normalized_name) do
    normalized_name
    |> String.downcase()
    |> first_hashtag_by_normalized_name()
  end

  defp first_hashtag_by_normalized_name(normalized_name) do
    from(h in Hashtag,
      where: h.normalized_name == ^normalized_name,
      order_by: [asc: h.id],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Counts posts with a specific hashtag (for ActivityPub collections).
  """
  def count_hashtag_posts(hashtag_id, opts \\ []) do
    hashtag_posts_query(hashtag_id, opts)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Lists posts with a specific hashtag (for ActivityPub collections).
  """
  def list_hashtag_posts(hashtag_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    preload = Keyword.get(opts, :preload, [])

    query =
      from(m in hashtag_posts_query(hashtag_id, opts),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        offset: ^offset
      )

    query
    |> Repo.all()
    |> Repo.preload(preload)
  end

  defp hashtag_posts_query(hashtag_id, opts) do
    visibility = Keyword.get(opts, :visibility)
    exclude_drafts = Keyword.get(opts, :exclude_drafts, false)
    activitypub_enabled_only = Keyword.get(opts, :activitypub_enabled_only, false)

    Message
    |> join(:inner, [m], ph in "post_hashtags", on: ph.message_id == m.id)
    |> join(:inner, [m, ph], c in Conversation, on: c.id == m.conversation_id)
    |> where([m, ph, _c], ph.hashtag_id == ^hashtag_id and is_nil(m.deleted_at))
    |> where([_m, _ph, c], c.type != "community" or c.is_public == true)
    |> maybe_filter_hashtag_post_visibility(visibility)
    |> maybe_exclude_hashtag_drafts(exclude_drafts)
    |> maybe_filter_activitypub_enabled_hashtag_posts(activitypub_enabled_only)
  end

  defp maybe_filter_hashtag_post_visibility(query, nil), do: query

  defp maybe_filter_hashtag_post_visibility(query, visibility) do
    from(m in query, where: m.visibility == ^visibility)
  end

  defp maybe_exclude_hashtag_drafts(query, false), do: query
  defp maybe_exclude_hashtag_drafts(query, true), do: from(m in query, where: m.is_draft != true)

  defp maybe_filter_activitypub_enabled_hashtag_posts(query, false), do: query

  defp maybe_filter_activitypub_enabled_hashtag_posts(query, true) do
    from([m, _ph, _c] in query,
      join: u in User,
      on: u.id == m.sender_id and u.activitypub_enabled == true
    )
  end
end
