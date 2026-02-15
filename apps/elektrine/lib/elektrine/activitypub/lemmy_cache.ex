defmodule Elektrine.ActivityPub.LemmyCache do
  @moduledoc """
  Cache for Lemmy post counts and top comments.
  Stores data in database to avoid slow API calls on page load.
  """

  use Ecto.Schema
  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.ActivityPub.LemmyApi

  @cache_ttl_minutes 15

  schema "lemmy_counts_cache" do
    field :activitypub_id, :string
    field :upvotes, :integer, default: 0
    field :downvotes, :integer, default: 0
    field :score, :integer, default: 0
    field :comments, :integer, default: 0
    field :top_comments, {:array, :map}, default: []
    field :fetched_at, :utc_datetime

    timestamps()
  end

  def changeset(cache, attrs) do
    cache
    |> Ecto.Changeset.cast(attrs, [
      :activitypub_id,
      :upvotes,
      :downvotes,
      :score,
      :comments,
      :top_comments,
      :fetched_at
    ])
    |> Ecto.Changeset.validate_required([:activitypub_id, :fetched_at])
  end

  @doc """
  Get cached counts for multiple posts.
  Returns a map of activitypub_id => %{upvotes, downvotes, score, comments}
  """
  def get_cached_counts(activitypub_ids) when is_list(activitypub_ids) do
    from(c in __MODULE__,
      where: c.activitypub_id in ^activitypub_ids,
      select:
        {c.activitypub_id,
         %{
           upvotes: c.upvotes,
           downvotes: c.downvotes,
           score: c.score,
           comments: c.comments
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Get cached top comments for multiple posts.
  Returns a map of activitypub_id => [comments]
  """
  def get_cached_comments(activitypub_ids) when is_list(activitypub_ids) do
    from(c in __MODULE__,
      where: c.activitypub_id in ^activitypub_ids and c.top_comments != [],
      select: {c.activitypub_id, c.top_comments}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Get both counts and comments for posts.
  Returns {counts_map, comments_map}
  """
  def get_cached_data(activitypub_ids) when is_list(activitypub_ids) do
    results =
      from(c in __MODULE__,
        where: c.activitypub_id in ^activitypub_ids,
        select: c
      )
      |> Repo.all()

    counts =
      results
      |> Enum.map(fn c ->
        {c.activitypub_id,
         %{
           upvotes: c.upvotes,
           downvotes: c.downvotes,
           score: c.score,
           comments: c.comments
         }}
      end)
      |> Map.new()

    comments =
      results
      |> Enum.filter(fn c -> c.top_comments != [] end)
      |> Enum.map(fn c -> {c.activitypub_id, c.top_comments} end)
      |> Map.new()

    {counts, comments}
  end

  @doc """
  Check which posts need their cache refreshed (stale or missing).
  Returns list of activitypub_ids that need updating.
  """
  def get_stale_ids(activitypub_ids) when is_list(activitypub_ids) do
    cutoff = DateTime.add(DateTime.utc_now(), -@cache_ttl_minutes, :minute)

    cached_fresh =
      from(c in __MODULE__,
        where: c.activitypub_id in ^activitypub_ids and c.fetched_at > ^cutoff,
        select: c.activitypub_id
      )
      |> Repo.all()
      |> MapSet.new()

    activitypub_ids
    |> Enum.filter(fn id -> not MapSet.member?(cached_fresh, id) end)
  end

  @doc """
  Update cache for a single post. Called by background worker.
  """
  def refresh_cache(activitypub_id) when is_binary(activitypub_id) do
    # Only fetch if it's a Lemmy post
    if String.contains?(activitypub_id, "/post/") do
      counts = LemmyApi.fetch_post_counts(activitypub_id) || %{}
      top_comments = LemmyApi.fetch_top_comments(activitypub_id, 3) || []

      attrs = %{
        activitypub_id: activitypub_id,
        upvotes: counts[:upvotes] || 0,
        downvotes: counts[:downvotes] || 0,
        score: counts[:score] || 0,
        comments: counts[:comments] || 0,
        top_comments: top_comments,
        fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      %__MODULE__{}
      |> changeset(attrs)
      |> Repo.insert(
        on_conflict:
          {:replace,
           [:upvotes, :downvotes, :score, :comments, :top_comments, :fetched_at, :updated_at]},
        conflict_target: :activitypub_id
      )
    else
      {:ok, nil}
    end
  end

  @doc """
  Schedule background refresh for posts that need updating.
  """
  def schedule_refresh(activitypub_ids) when is_list(activitypub_ids) do
    stale_ids = get_stale_ids(activitypub_ids)

    # Only schedule if there are stale posts
    if stale_ids != [] do
      # Schedule one job that handles all stale posts
      %{activitypub_ids: stale_ids}
      |> Elektrine.Workers.LemmyCacheWorker.new()
      |> Oban.insert()
    else
      {:ok, :no_stale}
    end
  end

  @doc """
  Clean up old cache entries (older than 24 hours).
  """
  def cleanup_old_entries do
    cutoff = DateTime.add(DateTime.utc_now(), -24, :hour)

    from(c in __MODULE__,
      where: c.fetched_at < ^cutoff
    )
    |> Repo.delete_all()
  end
end
