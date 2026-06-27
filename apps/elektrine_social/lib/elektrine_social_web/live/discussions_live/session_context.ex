defmodule ElektrineSocialWeb.DiscussionsLive.SessionContext do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias ElektrineSocialWeb.Components.Social.PostUtilities

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
    liked_creators = params["liked_creators"] || []
    liked_local_creators = params["liked_local_creators"] || liked_creators
    current_context = current_context || default()

    %{
      current_context
      | liked_hashtags:
          merge_recent_unique(current_context.liked_hashtags, params["liked_hashtags"] || [], 20),
        liked_creators: merge_recent_unique(current_context.liked_creators, liked_creators, 10),
        liked_local_creators:
          merge_recent_unique(current_context.liked_local_creators, liked_local_creators, 10),
        liked_remote_creators:
          merge_recent_unique(
            current_context.liked_remote_creators,
            params["liked_remote_creators"] || [],
            10
          ),
        viewed_posts:
          merge_recent_unique(current_context.viewed_posts, params["viewed_posts"] || [], 50),
        engagement_rate: coerce_float(params["engagement_rate"], current_context.engagement_rate)
    }
  end

  def personalization_score(post, session_context) do
    session_context = session_context || default()
    hashtags = extract_post_hashtags(post)
    hashtag_matches = Enum.count(hashtags, &(&1 in (session_context.liked_hashtags || [])))

    creator_bonus =
      cond do
        post.federated && post.remote_actor_id in (session_context.liked_remote_creators || []) ->
          28

        !post.federated && post.sender_id in (session_context.liked_local_creators || []) ->
          28

        true ->
          0
      end

    viewed_penalty =
      if normalize_post_id(post.id) in (session_context.viewed_posts || []) do
        -18
      else
        0
      end

    dismissed_penalty =
      if normalize_post_id(post.id) in (session_context.dismissed_posts || []) do
        -80
      else
        0
      end

    {_likes, replies} = PostUtilities.get_display_counts(post, %{}, %{})

    total_engagement =
      PostUtilities.display_primary_count(post) + replies + (post.share_count || 0)

    underexposed_bonus = if total_engagement <= 8, do: 6, else: 0
    media_bonus = if Enum.empty?(post.media_urls || []), do: 0, else: 4

    creator_bonus + hashtag_matches * 4 + viewed_penalty + dismissed_penalty + underexposed_bonus +
      media_bonus
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

  def maybe_note_dwell_interest(socket, post_id, dwell_time_ms) do
    if coerce_int(dwell_time_ms, 0) >= @session_interest_dwell_ms do
      post =
        Enum.find(socket.assigns.followed_community_posts || [], fn candidate ->
          candidate.id == normalize_post_id(post_id)
        end)

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
    session_context
    |> Map.update!(:liked_hashtags, &merge_recent_unique(&1, extract_post_hashtags(post), 20))
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

  defp extract_post_hashtags(post) do
    case Map.get(post, :hashtags) do
      hashtags when is_list(hashtags) -> Enum.map(hashtags, & &1.normalized_name)
      _ -> []
    end
  end

  defp normalize_post_id(post_id) when is_integer(post_id) and post_id > 0, do: post_id

  defp normalize_post_id(post_id) when is_binary(post_id) do
    case Integer.parse(post_id) do
      {value, ""} when value > 0 -> value
      _ -> nil
    end
  end

  defp normalize_post_id(_), do: nil

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

  defp default_if_nil(nil, default), do: default
  defp default_if_nil(value, _default), do: value
end
