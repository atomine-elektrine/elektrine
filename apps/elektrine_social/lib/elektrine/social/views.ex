defmodule Elektrine.Social.Views do
  @moduledoc """
  Tracks post views for analytics and recommendations.

  This module records when users view posts, enabling:
  - View count statistics
  - Recommendation algorithm inputs
  - Content engagement metrics
  """

  import Ecto.Query, warn: false
  alias Elektrine.Accounts.TrustLevel
  alias Elektrine.Messaging.Messages, as: MessagingMessages
  alias Elektrine.Repo
  alias Elektrine.Social.PostView

  @doc """
  Records that a user viewed a post.

  Used for recommendation algorithm and analytics.

  ## Options

    * `:view_duration_seconds` - How long the user viewed the post
    * `:completed` - Whether the user finished reading (scrolled to end)
    * `:dwell_time_ms` - Incremental dwell time recorded from feed tracking
    * `:scroll_depth` - Max visible portion of the post during this update
    * `:expanded` - Whether the user expanded the post content
    * `:source` - Where the user saw the post (timeline, discussion_detail, etc.)

  ## Examples

      iex> track_post_view(user_id, message_id)
      {:ok, %PostView{}}
      
      iex> track_post_view(user_id, message_id, view_duration_seconds: 30, completed: true)
      {:ok, %PostView{}}
  """
  def track_post_view(user_id, message_ref, opts \\ [])

  def track_post_view(user_id, message_ref, opts) when is_list(opts) or is_map(opts) do
    with {:ok, message_id} <- resolve_message_id(message_ref),
         {:ok, view, stat_updates} <- upsert_post_view(user_id, message_id, normalize_attrs(opts)) do
      apply_stat_updates(user_id, stat_updates)
      {:ok, view}
    end
  end

  @doc """
  Gets posts a user has viewed recently.

  ## Options

    * `:limit` - Maximum number of post IDs to return (default: 100)
    * `:days` - Number of days to look back (default: 7)

  Returns a list of message IDs, most recent first.
  """
  def get_user_viewed_posts(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    days_ago = Keyword.get(opts, :days, 7)
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-days_ago * 24 * 60 * 60)

    from(v in PostView,
      where: v.user_id == ^user_id and v.inserted_at > ^cutoff,
      order_by: [desc: v.inserted_at],
      limit: ^limit,
      select: v.message_id
    )
    |> Repo.all()
  end

  @doc """
  Gets view count for a post.

  Returns the total number of unique views.
  """
  def get_post_view_count(message_id) do
    from(v in PostView,
      where: v.message_id == ^message_id,
      select: count(v.id)
    )
    |> Repo.one()
  end

  @doc """
  Checks if user has viewed a post.
  """
  def user_viewed_post?(user_id, message_id) do
    from(v in PostView,
      where: v.user_id == ^user_id and v.message_id == ^message_id
    )
    |> Repo.exists?()
  end

  defp upsert_post_view(user_id, message_id, attrs) do
    insert_attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.put(:message_id, message_id)
      |> maybe_put_inserted_at()

    %PostView{}
    |> PostView.changeset(insert_attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :message_id],
      returning: true
    )
    |> case do
      {:ok, %PostView{id: nil}} ->
        update_existing_view(user_id, message_id, attrs)

      {:ok, %PostView{} = view} ->
        {:ok, view, stat_updates_for_new_view(attrs)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp update_existing_view(user_id, message_id, attrs) do
    existing =
      from(v in PostView,
        where: v.user_id == ^user_id and v.message_id == ^message_id,
        limit: 1
      )
      |> Repo.one()

    case existing do
      nil ->
        {:error, :not_found}

      view ->
        {changes, stat_updates} = build_view_changes(view, attrs)

        case changes do
          %{} = changes when map_size(changes) > 0 ->
            view
            |> PostView.update_dwell_changeset(changes)
            |> maybe_update_view_changeset(changes)
            |> Repo.update()
            |> case do
              {:ok, updated_view} -> {:ok, updated_view, stat_updates}
              {:error, changeset} -> {:error, changeset}
            end

          _ ->
            {:ok, view, stat_updates}
        end
    end
  end

  defp maybe_update_view_changeset(changeset, changes) do
    Ecto.Changeset.cast(
      changeset,
      changes,
      [:view_duration_seconds, :completed, :source]
    )
  end

  defp build_view_changes(view, attrs) do
    existing_dwell_ms = view.dwell_time_ms || 0
    incoming_dwell_ms = Map.get(attrs, :dwell_time_ms, 0) || 0
    new_dwell_ms = existing_dwell_ms + incoming_dwell_ms

    existing_duration_seconds = view_duration_seconds(view)
    incoming_duration_seconds = incoming_view_duration_seconds(attrs, new_dwell_ms)

    new_duration_seconds = max(existing_duration_seconds, incoming_duration_seconds)
    duration_delta_seconds = max(new_duration_seconds - existing_duration_seconds, 0)

    completed_now = Map.get(attrs, :completed, false) && !view.completed

    changes =
      %{}
      |> maybe_put_change(:dwell_time_ms, new_dwell_ms, existing_dwell_ms)
      |> maybe_put_change(
        :scroll_depth,
        max(view.scroll_depth || 0.0, Map.get(attrs, :scroll_depth, 0.0) || 0.0),
        view.scroll_depth
      )
      |> maybe_put_change(
        :expanded,
        view.expanded || Map.get(attrs, :expanded, false),
        view.expanded
      )
      |> maybe_put_change(
        :view_duration_seconds,
        new_duration_seconds,
        view.view_duration_seconds
      )
      |> maybe_put_change(:completed, true, view.completed, completed_now)
      |> maybe_put_change(:source, Map.get(attrs, :source), view.source)

    stat_updates =
      []
      |> maybe_add_stat(:time_read_seconds, duration_delta_seconds)
      |> maybe_add_stat(:topics_entered, if(completed_now, do: 1, else: 0))

    {changes, stat_updates}
  end

  defp stat_updates_for_new_view(attrs) do
    duration_seconds =
      incoming_view_duration_seconds(attrs, Map.get(attrs, :dwell_time_ms, 0) || 0)

    []
    |> maybe_add_stat(:posts_read, 1)
    |> maybe_add_stat(:time_read_seconds, duration_seconds)
    |> maybe_add_stat(:topics_entered, if(Map.get(attrs, :completed, false), do: 1, else: 0))
  end

  defp apply_stat_updates(_user_id, []), do: :ok

  defp apply_stat_updates(user_id, stat_updates) do
    Enum.each(stat_updates, fn {stat_name, amount} ->
      TrustLevel.increment_stat(user_id, stat_name, amount)
    end)
  end

  defp resolve_message_id(message_id) when is_integer(message_id) and message_id > 0,
    do: {:ok, message_id}

  defp resolve_message_id(message_id) when is_binary(message_id) do
    trimmed = String.trim(message_id)

    case Integer.parse(trimmed) do
      {parsed_id, ""} when parsed_id > 0 ->
        {:ok, parsed_id}

      _ ->
        case MessagingMessages.get_message_by_activitypub_ref(trimmed) do
          %{id: resolved_id} -> {:ok, resolved_id}
          _ -> {:error, :not_found}
        end
    end
  end

  defp resolve_message_id(_), do: {:error, :not_found}

  defp normalize_attrs(opts) when is_list(opts), do: opts |> Enum.into(%{}) |> normalize_attrs()

  defp normalize_attrs(opts) when is_map(opts) do
    %{
      view_duration_seconds:
        normalize_non_negative_integer(Map.get(opts, :view_duration_seconds)),
      completed: normalize_boolean(Map.get(opts, :completed, false)),
      dwell_time_ms: normalize_non_negative_integer(Map.get(opts, :dwell_time_ms)),
      scroll_depth: normalize_scroll_depth(Map.get(opts, :scroll_depth)),
      expanded: normalize_boolean(Map.get(opts, :expanded, false)),
      source: normalize_source(Map.get(opts, :source))
    }
  end

  defp normalize_non_negative_integer(nil), do: nil
  defp normalize_non_negative_integer(value) when is_integer(value), do: max(value, 0)

  defp normalize_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> max(parsed, 0)
      _ -> nil
    end
  end

  defp normalize_non_negative_integer(_), do: nil

  defp normalize_boolean(value) when value in [true, "true", "1", 1], do: true
  defp normalize_boolean(_), do: false

  defp normalize_scroll_depth(nil), do: nil

  defp normalize_scroll_depth(value) when is_float(value) do
    value |> max(0.0) |> min(1.0)
  end

  defp normalize_scroll_depth(value) when is_integer(value) do
    (value / 1) |> normalize_scroll_depth()
  end

  defp normalize_scroll_depth(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> normalize_scroll_depth(parsed)
      _ -> nil
    end
  end

  defp normalize_scroll_depth(_), do: nil

  defp normalize_source(source) when is_binary(source) do
    case String.trim(source) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_source(_), do: nil

  defp maybe_put_inserted_at(attrs) do
    Map.put_new(attrs, :inserted_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))
  end

  defp view_duration_seconds(%PostView{} = view) do
    max(view.view_duration_seconds || 0, div(view.dwell_time_ms || 0, 1000))
  end

  defp incoming_view_duration_seconds(attrs, dwell_time_ms) do
    max(Map.get(attrs, :view_duration_seconds, 0) || 0, div(dwell_time_ms || 0, 1000))
  end

  defp maybe_put_change(changes, field, new_value, old_value) do
    maybe_put_change(changes, field, new_value, old_value, true)
  end

  defp maybe_put_change(changes, _field, _new_value, _old_value, false), do: changes

  defp maybe_put_change(changes, field, new_value, old_value, true) do
    if is_nil(new_value) or new_value == old_value do
      changes
    else
      Map.put(changes, field, new_value)
    end
  end

  defp maybe_add_stat(stat_updates, _stat_name, amount) when amount in [nil, 0], do: stat_updates
  defp maybe_add_stat(stat_updates, stat_name, amount), do: [{stat_name, amount} | stat_updates]
end
