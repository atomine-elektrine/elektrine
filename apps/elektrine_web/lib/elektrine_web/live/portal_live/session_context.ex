defmodule ElektrineWeb.PortalLive.SessionContext do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  @session_interest_dwell_ms 10_000

  def default do
    %{
      liked_hashtags: [],
      liked_creators: [],
      liked_local_creators: [],
      liked_remote_creators: [],
      viewed_posts: [],
      dismissed_posts: [],
      total_views: 0,
      total_interactions: 0,
      engagement_rate: 0.0
    }
  end

  def update_from_params(current_context, params) when is_map(params) do
    current_context = current_context || default()
    liked_creators = params["liked_creators"] || []
    liked_local_creators = params["liked_local_creators"] || liked_creators

    %{
      current_context
      | liked_hashtags:
          merge_recent_unique(
            current_context[:liked_hashtags],
            params["liked_hashtags"] || [],
            20
          ),
        liked_creators: merge_recent_unique([], liked_creators, 10),
        liked_local_creators:
          merge_recent_unique(current_context[:liked_local_creators], liked_local_creators, 10),
        liked_remote_creators:
          merge_recent_unique(
            current_context[:liked_remote_creators],
            params["liked_remote_creators"] || [],
            10
          ),
        viewed_posts:
          merge_recent_unique(current_context[:viewed_posts], params["viewed_posts"] || [], 50),
        engagement_rate:
          coerce_float(params["engagement_rate"], current_context[:engagement_rate] || 0.0)
    }
  end

  def note_positive(socket, nil), do: socket

  def note_positive(socket, post) do
    session_context =
      socket.assigns[:session_context]
      |> default_if_nil(default())
      |> merge_positive_signal(post, 1)

    assign(socket, :session_context, session_context)
  end

  def note_view(socket, post_id) do
    normalized_post_id = normalize_post_id(post_id)

    if is_nil(normalized_post_id) do
      socket
    else
      session_context =
        socket.assigns[:session_context]
        |> default_if_nil(default())
        |> merge_view_signal(normalized_post_id)

      assign(socket, :session_context, session_context)
    end
  end

  def maybe_note_dwell_interest(socket, post, dwell_time_ms) do
    if coerce_int(dwell_time_ms, 0) >= @session_interest_dwell_ms do
      note_positive(socket, post)
    else
      socket
    end
  end

  def note_dismissal(socket, post_id) do
    normalized_post_id = normalize_post_id(post_id)

    if is_nil(normalized_post_id) do
      socket
    else
      session_context =
        socket.assigns[:session_context]
        |> default_if_nil(default())
        |> Map.update!(:dismissed_posts, &merge_recent_unique(&1, [normalized_post_id], 50))

      assign(socket, :session_context, session_context)
    end
  end

  defp merge_positive_signal(session_context, post, interaction_increment) do
    hashtags =
      case Map.get(post, :hashtags) do
        hashtags when is_list(hashtags) -> Enum.map(hashtags, & &1.normalized_name)
        _ -> []
      end

    session_context
    |> Map.update!(:liked_hashtags, &merge_recent_unique(&1, hashtags, 20))
    |> Map.update!(:liked_local_creators, fn creators ->
      if post.federated do
        creators
      else
        merge_recent_unique(creators, [post.sender_id], 10)
      end
    end)
    |> Map.update!(:liked_remote_creators, fn creators ->
      if post.federated do
        merge_recent_unique(creators, [post.remote_actor_id], 10)
      else
        creators
      end
    end)
    |> then(fn context ->
      Map.put(context, :liked_creators, context.liked_local_creators)
    end)
    |> Map.update!(:total_interactions, &(&1 + interaction_increment))
    |> refresh_engagement_rate()
  end

  defp merge_view_signal(session_context, post_id) do
    already_viewed = post_id in (session_context.viewed_posts || [])

    session_context
    |> Map.update!(:viewed_posts, &merge_recent_unique(&1, [post_id], 50))
    |> Map.update!(:total_views, fn count -> if(already_viewed, do: count, else: count + 1) end)
    |> refresh_engagement_rate()
  end

  defp refresh_engagement_rate(session_context) do
    total_views =
      max(session_context.total_views || length(session_context.viewed_posts || []), 1)

    total_interactions = session_context.total_interactions || 0
    Map.put(session_context, :engagement_rate, total_interactions / total_views)
  end

  defp normalize_post_id(post_id) when is_integer(post_id) and post_id > 0, do: post_id

  defp normalize_post_id(post_id) when is_binary(post_id) do
    case Integer.parse(post_id) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp normalize_post_id(_), do: nil

  defp coerce_int(value, _default) when is_integer(value), do: value

  defp coerce_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp coerce_int(_, default), do: default

  defp coerce_float(value, _default) when is_float(value), do: value
  defp coerce_float(value, _default) when is_integer(value), do: value / 1

  defp coerce_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _ -> default
    end
  end

  defp coerce_float(_, default), do: default

  defp merge_recent_unique(values, additions, limit) do
    Enum.reduce(List.wrap(additions), values || [], fn value, acc ->
      if is_nil(value) or (is_binary(value) and not Elektrine.Strings.present?(value)) do
        acc
      else
        (Enum.reject(acc, &(&1 == value)) ++ [value])
        |> trim_recent(limit)
      end
    end)
  end

  defp trim_recent(values, limit) when is_list(values) and length(values) > limit do
    Enum.take(values, -limit)
  end

  defp trim_recent(values, _limit), do: values

  defp default_if_nil(nil, default), do: default
  defp default_if_nil(value, _default), do: value
end
