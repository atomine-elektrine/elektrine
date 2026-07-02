defmodule Elektrine.Social.TimelineLoadVerifier do
  @moduledoc """
  Seeds and verifies combined home timeline pagination under local load.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts
  alias Elektrine.Profiles
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.{Conversation, HomeFeedCache, Message}

  @default_count 60
  @default_page_size 20
  @default_password "timeline verifier password"

  def run(opts \\ []) do
    count = positive_int(Keyword.get(opts, :count), @default_count)
    page_size = positive_int(Keyword.get(opts, :page_size), @default_page_size)
    max_pages = positive_int(Keyword.get(opts, :max_pages), div(count, page_size) + 10)
    prefix = Keyword.get(opts, :prefix) || default_prefix()

    with {:ok, viewer} <-
           get_or_create_user(
             Keyword.get(opts, :viewer_username) || username_for(prefix, "viewer")
           ),
         {:ok, author} <-
           get_or_create_user(
             Keyword.get(opts, :author_username) || username_for(prefix, "author")
           ),
         :ok <- ensure_distinct_users(viewer, author),
         {:ok, _follow} <- ensure_follow(viewer.id, author.id),
         {:ok, seeded_ids} <- seed_posts(author, count, prefix) do
      HomeFeedCache.clear(viewer.id)

      verify_existing(viewer.id, seeded_ids,
        page_size: page_size,
        max_pages: max_pages,
        prefix: prefix,
        author_id: author.id
      )
      |> add_seed_summary(viewer, author, count)
    end
  end

  def verify_existing(viewer_id, expected_ids, opts \\ [])
      when is_integer(viewer_id) and is_list(expected_ids) do
    page_size = positive_int(Keyword.get(opts, :page_size), @default_page_size)

    max_pages =
      positive_int(
        Keyword.get(opts, :max_pages),
        div(max(length(expected_ids), 1), page_size) + 10
      )

    expected_ids = expected_ids |> Enum.filter(&is_integer/1) |> Enum.uniq() |> Enum.sort(:desc)

    pages = collect_pages(viewer_id, page_size, max_pages)
    ids = pages |> Enum.flat_map(& &1.ids)
    duplicate_ids = duplicate_ids(ids)
    found_expected_ids = Enum.filter(ids, &(&1 in expected_ids))
    missing_expected_ids = expected_ids -- found_expected_ids

    cond do
      expected_ids == [] ->
        {:error, %{reason: :no_expected_ids}}

      duplicate_ids != [] ->
        {:error, %{reason: :duplicate_ids, duplicate_ids: duplicate_ids, pages: pages}}

      not descending?(ids) ->
        {:error, %{reason: :not_descending, ids: ids, pages: pages}}

      missing_expected_ids != [] ->
        {:error,
         %{
           reason: :missing_seeded_posts,
           missing_ids: missing_expected_ids,
           found_count: length(found_expected_ids),
           expected_count: length(expected_ids),
           pages: pages
         }}

      true ->
        {:ok,
         %{
           viewer_id: viewer_id,
           expected_count: length(expected_ids),
           found_count: length(found_expected_ids),
           page_size: page_size,
           pages_checked: length(pages),
           loaded_count: length(ids),
           first_id: List.first(ids),
           last_id: List.last(ids),
           prefix: Keyword.get(opts, :prefix),
           author_id: Keyword.get(opts, :author_id)
         }}
    end
  end

  defp collect_pages(viewer_id, page_size, max_pages) do
    Enum.reduce_while(1..max_pages, {nil, []}, fn page_number, {before_id, pages} ->
      opts =
        [limit: page_size]
        |> maybe_put_before_id(before_id)

      posts = Social.get_combined_feed(viewer_id, opts)
      ids = Enum.map(posts, & &1.id)
      page = %{page: page_number, before_id: before_id, ids: ids}

      cond do
        ids == [] ->
          {:halt, {before_id, pages}}

        length(ids) < page_size ->
          {:halt, {List.last(ids), [page | pages]}}

        true ->
          {:cont, {List.last(ids), [page | pages]}}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp maybe_put_before_id(opts, nil), do: opts
  defp maybe_put_before_id(opts, before_id), do: Keyword.put(opts, :before_id, before_id)

  defp seed_posts(author, count, prefix) do
    conversation = get_or_create_timeline_conversation(author)

    seeded_ids =
      1..count
      |> Enum.map(fn index ->
        %Message{}
        |> Message.changeset(%{
          conversation_id: conversation.id,
          sender_id: author.id,
          content: "#{prefix} load post #{index}",
          message_type: "text",
          visibility: "public",
          post_type: "post",
          like_count: 0,
          reply_count: 0,
          share_count: 0,
          score: 0,
          approval_status: "approved"
        })
        |> Repo.insert!()
        |> Map.fetch!(:id)
      end)

    {:ok, Enum.sort(seeded_ids, :desc)}
  rescue
    error -> {:error, %{reason: :seed_failed, error: Exception.message(error)}}
  end

  defp get_or_create_timeline_conversation(author) do
    Repo.one(
      from c in Conversation,
        where: c.creator_id == ^author.id and c.type == "timeline",
        order_by: [asc: c.id],
        limit: 1
    ) ||
      %Conversation{}
      |> Conversation.changeset(%{
        name: "Timeline",
        type: "timeline",
        creator_id: author.id,
        is_public: true,
        allow_public_posts: true
      })
      |> Repo.insert!()
  end

  defp get_or_create_user(username) do
    username = normalize_username(username)

    case Repo.get_by(Accounts.User, username: username) do
      %Accounts.User{} = user ->
        {:ok, user}

      nil ->
        Accounts.create_user(%{
          username: username,
          password: @default_password,
          password_confirmation: @default_password
        })
    end
  end

  defp ensure_follow(viewer_id, author_id) do
    if Profiles.following?(viewer_id, author_id) do
      {:ok, :already_following}
    else
      Profiles.follow_user(viewer_id, author_id)
    end
  end

  defp add_seed_summary({:ok, summary}, viewer, author, count) do
    {:ok,
     summary
     |> Map.put(:seeded_count, count)
     |> Map.put(:viewer_username, viewer.username)
     |> Map.put(:author_username, author.username)}
  end

  defp add_seed_summary(error, _viewer, _author, _count), do: error

  defp duplicate_ids(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, count} -> count > 1 end)
    |> Enum.map(fn {id, _count} -> id end)
    |> Enum.sort(:desc)
  end

  defp descending?([]), do: true
  defp descending?([_]), do: true

  defp descending?(ids) do
    ids
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> left > right end)
  end

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int(value, default) when is_binary(value),
    do: value |> Integer.parse() |> parsed_positive(default)

  defp positive_int(_value, default), do: default

  defp parsed_positive({value, ""}, _default) when value > 0, do: value
  defp parsed_positive(_parsed, default), do: default

  defp default_prefix do
    "tl#{System.unique_integer([:positive])}"
  end

  defp normalize_username(username) do
    normalized =
      username
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "")
      |> String.slice(0, 24)

    if normalized == "", do: "timelineuser", else: normalized
  end

  defp username_for(prefix, suffix) do
    prefix =
      prefix
      |> normalize_username()
      |> String.slice(0, 16)

    normalize_username("#{prefix}#{suffix}")
  end

  defp ensure_distinct_users(%{id: id}, %{id: id}), do: {:error, %{reason: :same_user}}
  defp ensure_distinct_users(_viewer, _author), do: :ok
end
