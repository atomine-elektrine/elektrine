defmodule Elektrine.ActivityPub.LemmyApi do
  @moduledoc """
  Helper module for fetching data from Lemmy instances via their JSON API.
  """

  @doc """
  Fetch post counts (upvotes, downvotes, score, comments) from a Lemmy instance.
  Returns nil if the post is not from a Lemmy instance or if the fetch fails.
  """
  def fetch_post_counts(post_url) when is_binary(post_url) do
    case resolve_post_reference(post_url) do
      {:ok, domain, post_id} ->
        api_url = "https://#{domain}/api/v3/post?id=#{post_id}"
        headers = [{"Accept", "application/json"}, {"User-Agent", "Elektrine/1.0"}]

        case Finch.build(:get, api_url, headers)
             |> Finch.request(Elektrine.Finch, receive_timeout: 5_000) do
          {:ok, %Finch.Response{status: 200, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"post_view" => %{"counts" => counts}}} ->
                %{
                  upvotes: counts["upvotes"] || 0,
                  downvotes: counts["downvotes"] || 0,
                  score: counts["score"] || 0,
                  comments: counts["comments"] || 0
                }

              _ ->
                nil
            end

          {:ok, %Finch.Response{status: _status}} ->
            nil

          {:error, _reason} ->
            nil
        end

      :error ->
        nil
    end
  end

  def fetch_post_counts(_), do: nil

  @doc """
  Fetch counts for multiple Lemmy posts in parallel.
  Returns a map of activitypub_id => counts.
  Uses yield_many to avoid blocking on slow/failed requests.
  """
  def fetch_posts_counts(posts) when is_list(posts) do
    tasks =
      posts
      |> Enum.filter(&is_lemmy_post?/1)
      |> Enum.map(fn post ->
        Task.async(fn ->
          activitypub_id = get_activitypub_id(post)
          post_url = activitypub_id || get_activitypub_url(post)
          counts = fetch_post_counts(post_url)
          {activitypub_id, counts}
        end)
      end)

    # Use yield_many with 3s timeout - accept whatever completes in time
    results = Task.yield_many(tasks, timeout: 3_000)

    # Shutdown any tasks that didn't complete
    Enum.each(results, fn {task, result} ->
      if result == nil, do: Task.shutdown(task, :brutal_kill)
    end)

    # Collect successful results
    results
    |> Enum.flat_map(fn
      {_task, {:ok, {id, counts}}} when counts != nil -> [{id, counts}]
      _ -> []
    end)
    |> Map.new()
  end

  @doc """
  Fetch comment counts for a Lemmy post.
  Returns a map of comment_ap_id => %{score, upvotes, downvotes, child_count}
  """
  def fetch_comment_counts(post_url) when is_binary(post_url) do
    case resolve_post_reference(post_url) do
      {:ok, domain, post_id} ->
        api_url = "https://#{domain}/api/v3/comment/list?post_id=#{post_id}&limit=100"
        headers = [{"Accept", "application/json"}, {"User-Agent", "Elektrine/1.0"}]

        case Finch.build(:get, api_url, headers)
             |> Finch.request(Elektrine.Finch, receive_timeout: 10_000) do
          {:ok, %Finch.Response{status: 200, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"comments" => comments}} ->
                comments
                |> Enum.map(fn comment_view ->
                  ap_id = get_in(comment_view, ["comment", "ap_id"])
                  counts = comment_view["counts"] || %{}

                  {ap_id,
                   %{
                     score: counts["score"] || 0,
                     upvotes: counts["upvotes"] || 0,
                     downvotes: counts["downvotes"] || 0,
                     child_count: counts["child_count"] || 0
                   }}
                end)
                |> Enum.filter(fn {ap_id, _} -> ap_id != nil end)
                |> Map.new()

              _ ->
                %{}
            end

          {:ok, %Finch.Response{status: _status}} ->
            %{}

          {:error, _reason} ->
            %{}
        end

      :error ->
        %{}
    end
  end

  def fetch_comment_counts(_), do: %{}

  @doc """
  Fetch top comments for a Lemmy post with content.
  Returns a list of comment maps with :author, :content, :score, :ap_id
  Sorted by score (top comments first), limited to top 3.
  """
  def fetch_top_comments(post_url, limit \\ 3)

  def fetch_top_comments(post_url, limit) when is_binary(post_url) do
    case resolve_post_reference(post_url) do
      {:ok, domain, post_id} ->
        # Sort by Top to get highest scored comments, only get top-level (parent_id not set)
        api_url =
          "https://#{domain}/api/v3/comment/list?post_id=#{post_id}&sort=Top&limit=#{limit}&max_depth=1"

        headers = [{"Accept", "application/json"}, {"User-Agent", "Elektrine/1.0"}]

        case Finch.build(:get, api_url, headers)
             |> Finch.request(Elektrine.Finch, receive_timeout: 5_000) do
          {:ok, %Finch.Response{status: 200, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"comments" => comments}} ->
                comments
                |> Enum.take(limit)
                |> Enum.map(fn comment_view ->
                  comment = comment_view["comment"] || %{}
                  creator = comment_view["creator"] || %{}
                  counts = comment_view["counts"] || %{}

                  %{
                    ap_id: comment["ap_id"],
                    content: comment["content"] || "",
                    author: creator["name"] || creator["display_name"] || "unknown",
                    author_domain: extract_domain(creator["actor_id"]),
                    actor_id: creator["actor_id"],
                    author_avatar: creator["avatar"],
                    published: comment["published"],
                    score: counts["score"] || 0,
                    upvotes: counts["upvotes"] || 0,
                    child_count: counts["child_count"] || 0
                  }
                end)

              _ ->
                []
            end

          {:ok, %Finch.Response{status: _status}} ->
            []

          {:error, _reason} ->
            []
        end

      :error ->
        []
    end
  end

  def fetch_top_comments(_, _), do: []

  @doc """
  Fetch top comments for multiple Lemmy posts in parallel.
  Returns a map of activitypub_id => [comments]
  """
  def fetch_posts_top_comments(posts, limit \\ 3) when is_list(posts) do
    posts
    |> Enum.filter(&is_lemmy_post?/1)
    |> Enum.map(fn post ->
      Task.async(fn ->
        activitypub_id = get_activitypub_id(post)
        post_url = activitypub_id || get_activitypub_url(post)
        comments = fetch_top_comments(post_url, limit)
        {activitypub_id, comments}
      end)
    end)
    |> Task.await_many(15_000)
    |> Enum.filter(fn {_id, comments} -> comments != [] end)
    |> Map.new()
  end

  defp extract_domain(url), do: Elektrine.TextHelpers.extract_domain_from_url(url)

  # Check if a post is from a Lemmy-compatible community platform.
  defp is_lemmy_post?(post) do
    activitypub_id = get_activitypub_id(post)
    activitypub_url = get_activitypub_url(post)
    community_uri = get_community_actor_uri(post)

    (is_binary(activitypub_id) && community_post_url?(activitypub_id)) ||
      (is_binary(activitypub_url) && community_post_url?(activitypub_url)) ||
      is_binary(community_uri)
  end

  defp get_activitypub_id(%{activitypub_id: id}) when is_binary(id), do: id
  defp get_activitypub_id(%{"id" => id}) when is_binary(id), do: id
  defp get_activitypub_id(_), do: nil

  defp get_activitypub_url(%{activitypub_url: url}) when is_binary(url), do: url
  defp get_activitypub_url(%{"url" => url}) when is_binary(url), do: url
  defp get_activitypub_url(_), do: nil

  defp get_community_actor_uri(%{media_metadata: metadata}) when is_map(metadata) do
    metadata["community_actor_uri"]
  end

  defp get_community_actor_uri(%{"media_metadata" => metadata}) when is_map(metadata) do
    metadata["community_actor_uri"]
  end

  defp get_community_actor_uri(_), do: nil

  defp community_post_url?(url) when is_binary(url) do
    String.contains?(url, "/post/") ||
      Regex.match?(~r{/c/[^/]+/p/\d+}, url) ||
      Regex.match?(~r{/m/[^/]+/[pt]/\d+}, url)
  end

  defp community_post_url?(_), do: false

  defp resolve_post_reference(post_url) do
    case Regex.run(~r{https?://([^/]+)/post/(\d+)}, post_url) do
      [_, domain, post_id] ->
        {:ok, domain, post_id}

      _ ->
        case Regex.run(~r{https?://([^/]+)/c/[^/]+/p/(\d+)}, post_url) do
          [_, domain, post_id] ->
            {:ok, domain, post_id}

          _ ->
            case Regex.run(~r{https?://([^/]+)/m/[^/]+/[pt]/(\d+)}, post_url) do
              [_, domain, post_id] ->
                {:ok, domain, post_id}

              _ ->
                resolve_post_reference_via_api(post_url)
            end
        end
    end
  end

  defp resolve_post_reference_via_api(post_url) do
    case URI.parse(post_url) do
      %URI{host: domain} when is_binary(domain) ->
        resolve_url = "https://#{domain}/api/v3/resolve_object?q=#{URI.encode_www_form(post_url)}"

        case Finch.build(:get, resolve_url, [{"Accept", "application/json"}])
             |> Finch.request(Elektrine.Finch, receive_timeout: 10_000) do
          {:ok, %Finch.Response{status: 200, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"post" => %{"post" => %{"id" => post_id}}}} when is_integer(post_id) ->
                {:ok, domain, Integer.to_string(post_id)}

              {:ok, %{"post" => %{"post" => %{"id" => post_id}}}} when is_binary(post_id) ->
                {:ok, domain, post_id}

              _ ->
                :error
            end

          _ ->
            :error
        end

      _ ->
        :error
    end
  end
end
