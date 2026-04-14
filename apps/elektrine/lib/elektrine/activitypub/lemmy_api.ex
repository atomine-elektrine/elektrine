defmodule Elektrine.ActivityPub.LemmyApi do
  @moduledoc """
  Helper module for fetching data from Lemmy instances via their JSON API.
  """

  alias Elektrine.HTTP.SafeFetch

  @doc """
  Fetch post counts (upvotes, downvotes, score, comments) from a Lemmy instance.
  Returns nil if the post is not from a Lemmy instance or if the fetch fails.
  """
  def fetch_post_counts(post_url) when is_binary(post_url) do
    case resolve_post_reference(post_url) do
      {:ok, domain, post_id} ->
        api_url = "https://#{domain}/api/v4/post?id=#{post_id}"
        headers = [{"Accept", "application/json"}, {"User-Agent", "Elektrine/1.0"}]

        case safe_request_lemmy_api(:get, api_url, headers, nil, receive_timeout: 5_000) do
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
                fetch_post_counts_from_html(post_url)
            end

          {:ok, %Finch.Response{status: _status}} ->
            fetch_post_counts_from_html(post_url)

          {:error, _reason} ->
            fetch_post_counts_from_html(post_url)
        end

      :error ->
        fetch_post_counts_from_html(post_url)
    end
  end

  def fetch_post_counts(_), do: nil

  @doc """
  Fetch member and post counts for a Lemmy community.

  Returns `%{members: count, posts: count}` on success, or `nil` if the
  community is not found or the instance is not Lemmy-compatible.
  """
  def fetch_community_counts(domain, community_name)
      when is_binary(domain) and is_binary(community_name) do
    api_url = "https://#{domain}/api/v4/community?name=#{URI.encode_www_form(community_name)}"
    headers = [{"Accept", "application/json"}, {"User-Agent", "Elektrine/1.0"}]

    case safe_request_lemmy_api(:get, api_url, headers, nil, receive_timeout: 5_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"community_view" => %{"counts" => counts}}} ->
            %{
              members: parse_count(counts["subscribers"]),
              posts: parse_count(counts["posts"])
            }

          _ ->
            nil
        end

      {:ok, %Finch.Response{status: _status}} ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  def fetch_community_counts(_, _), do: nil

  @doc """
  Fetch counts for multiple Lemmy posts in parallel.
  Returns a map of activitypub_id => counts.
  Uses yield_many to avoid blocking on slow/failed requests.
  """
  def fetch_posts_counts(posts) when is_list(posts) do
    tasks =
      posts
      |> Enum.filter(&lemmy_post?/1)
      |> Enum.map(fn post ->
        Task.async(fn ->
          activitypub_id = get_activitypub_id(post)
          post_url = activitypub_id || get_activitypub_url(post)
          counts = fetch_post_counts(post_url)
          {activitypub_id, counts}
        end)
      end)

    # Use a slightly longer timeout for busy Lemmy instances.
    results = Task.yield_many(tasks, timeout: 6_000)

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
        domain
        |> fetch_comment_counts_pages(post_id, 100, 1, %{})
        |> case do
          %{} = counts when map_size(counts) > 0 -> counts
          _ -> fetch_comment_counts_from_post_comments(post_url)
        end

      :error ->
        fetch_comment_counts_from_post_comments(post_url)
    end
  end

  def fetch_comment_counts(_), do: %{}

  defp fetch_comment_counts_pages(_domain, _post_id, _page_size, page, acc) when page > 10,
    do: acc

  defp fetch_comment_counts_pages(domain, post_id, page_size, page, acc) do
    api_url =
      "https://#{domain}/api/v4/comment/list?post_id=#{post_id}&limit=#{page_size}&page=#{page}&max_depth=10"

    headers = [{"Accept", "application/json"}, {"User-Agent", "Elektrine/1.0"}]

    case safe_request_lemmy_api(:get, api_url, headers, nil, receive_timeout: 10_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"comments" => comments}} when is_list(comments) ->
            updated_acc =
              Enum.reduce(comments, acc, fn comment_view, current_acc ->
                ap_id = get_in(comment_view, ["comment", "ap_id"])
                counts = comment_view["counts"] || %{}

                if is_binary(ap_id) do
                  Map.put(current_acc, ap_id, %{
                    score: counts["score"] || 0,
                    upvotes: counts["upvotes"] || 0,
                    downvotes: counts["downvotes"] || 0,
                    child_count: counts["child_count"] || 0
                  })
                else
                  current_acc
                end
              end)

            cond do
              comments == [] ->
                updated_acc

              length(comments) < page_size ->
                updated_acc

              true ->
                fetch_comment_counts_pages(domain, post_id, page_size, page + 1, updated_acc)
            end

          _ ->
            acc
        end

      _ ->
        acc
    end
  end

  defp fetch_comment_counts_from_post_comments(post_url) when is_binary(post_url) do
    post_url
    |> fetch_post_comments(500)
    |> Enum.reduce(%{}, fn
      %{"id" => ap_id} = comment, acc when is_binary(ap_id) ->
        Map.put(acc, ap_id, %{
          score: parse_count(comment["score"]),
          upvotes: parse_count(comment["upvotes"]),
          downvotes: parse_count(comment["downvotes"]),
          child_count: extract_collection_total(comment["replies"])
        })

      _, acc ->
        acc
    end)
  end

  defp fetch_comment_counts_from_post_comments(_), do: %{}

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
          "https://#{domain}/api/v4/comment/list?post_id=#{post_id}&sort=Top&limit=#{limit}&max_depth=1"

        headers = [{"Accept", "application/json"}, {"User-Agent", "Elektrine/1.0"}]

        case safe_request_lemmy_api(:get, api_url, headers, nil, receive_timeout: 5_000) do
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
  Fetch all available comments for a Lemmy post with content and parent refs.
  Returns a list of ActivityPub-like comment maps suitable for local storage.
  """
  def fetch_post_comments(post_url, limit \\ 100)

  def fetch_post_comments(post_url, limit) when is_binary(post_url) do
    case resolve_post_reference(post_url) do
      {:ok, domain, post_id} ->
        api_url =
          "https://#{domain}/api/v4/comment/list?post_id=#{post_id}&limit=#{limit}&max_depth=10"

        headers = [{"Accept", "application/json"}, {"User-Agent", "Elektrine/1.0"}]

        case safe_request_lemmy_api(:get, api_url, headers, nil, receive_timeout: 10_000) do
          {:ok, %Finch.Response{status: 200, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"comments" => comments}} when is_list(comments) ->
                comment_id_to_ap =
                  comments
                  |> Enum.reduce(%{}, fn comment_view, acc ->
                    comment = comment_view["comment"] || %{}

                    case {comment["id"], comment["ap_id"]} do
                      {id, ap_id} when is_integer(id) and is_binary(ap_id) ->
                        Map.put(acc, Integer.to_string(id), ap_id)

                      {id, ap_id} when is_binary(id) and is_binary(ap_id) ->
                        Map.put(acc, id, ap_id)

                      _ ->
                        acc
                    end
                  end)

                Enum.map(comments, &lemmy_comment_to_ap(&1, comment_id_to_ap, post_url))
                |> Enum.reject(&is_nil/1)

              _ ->
                []
            end

          _ ->
            []
        end

      :error ->
        []
    end
  end

  def fetch_post_comments(_, _), do: []

  @doc """
  Fetch top comments for multiple Lemmy posts in parallel.
  Returns a map of activitypub_id => [comments]
  """
  def fetch_posts_top_comments(posts, limit \\ 3) when is_list(posts) do
    tasks =
      posts
      |> Enum.filter(&lemmy_post?/1)
      |> Enum.map(fn post ->
        Task.async(fn ->
          activitypub_id = get_activitypub_id(post)
          post_url = activitypub_id || get_activitypub_url(post)
          comments = fetch_top_comments(post_url, limit)
          {activitypub_id, comments}
        end)
      end)

    results = Task.yield_many(tasks, timeout: 6_000)

    Enum.each(results, fn {task, result} ->
      if result == nil, do: Task.shutdown(task, :brutal_kill)
    end)

    results
    |> Enum.flat_map(fn
      {_task, {:ok, {id, comments}}} when is_binary(id) and comments != [] -> [{id, comments}]
      _ -> []
    end)
    |> Map.new()
  end

  defp extract_domain(url), do: Elektrine.TextHelpers.extract_domain_from_url(url)

  defp lemmy_comment_to_ap(comment_view, comment_id_to_ap, post_url) when is_map(comment_view) do
    comment = comment_view["comment"] || %{}
    creator = comment_view["creator"] || %{}
    counts = comment_view["counts"] || %{}

    ap_id = comment["ap_id"]
    actor_id = creator["actor_id"]

    if is_binary(ap_id) && is_binary(actor_id) do
      %{
        "id" => ap_id,
        "type" => "Note",
        "content" => comment["content"] || "",
        "published" => comment["published"],
        "attributedTo" => actor_id,
        "inReplyTo" => parse_lemmy_parent_ref(comment, comment_id_to_ap, post_url),
        "likes" => %{"totalItems" => counts["upvotes"] || 0},
        "replies" => %{"totalItems" => counts["child_count"] || 0},
        "shares" => %{"totalItems" => 0},
        "upvotes" => counts["upvotes"] || 0,
        "downvotes" => counts["downvotes"] || 0,
        "score" => counts["score"] || 0,
        "sensitive" => false
      }
    end
  end

  defp lemmy_comment_to_ap(_, _, _), do: nil

  defp parse_lemmy_parent_ref(comment, comment_id_to_ap, post_url) when is_map(comment) do
    path = comment["path"]

    case path do
      value when is_binary(value) ->
        segments = String.split(value, ".")

        case Enum.reverse(segments) do
          [_self, parent_id | _] when is_binary(parent_id) and parent_id != "" ->
            Map.get(comment_id_to_ap, parent_id, post_url)

          _ ->
            post_url
        end

      _ ->
        post_url
    end
  end

  defp parse_lemmy_parent_ref(_, _, post_url), do: post_url

  # Check if a post is from a Lemmy-compatible community platform.
  defp lemmy_post?(post) do
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

  @doc """
  Returns true when the URL matches a Lemmy/PieFed/Mbin community post pattern.

  This intentionally requires a numeric post id for `/post/<id>` so URLs like
  `bsky.app/profile/.../post/<rkey>` are not treated as Lemmy posts.
  """
  def community_post_url?(url) when is_binary(url) do
    Regex.match?(~r{/post/\d+(?:$|[/?#])}, url) ||
      Regex.match?(~r{/c/[^/]+/p/\d+(?:$|[/?#])}, url) ||
      Regex.match?(~r{/m/[^/]+/[pt]/\d+(?:$|[/?#])}, url)
  end

  def community_post_url?(_), do: false

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
        resolve_url = "https://#{domain}/api/v4/resolve_object?q=#{URI.encode_www_form(post_url)}"

        case safe_request_lemmy_api(:get, resolve_url, [{"Accept", "application/json"}], nil,
               receive_timeout: 10_000
             ) do
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

  defp parse_count(value) when is_integer(value), do: max(value, 0)

  defp parse_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> max(parsed, 0)
      :error -> 0
    end
  end

  defp parse_count(_), do: 0

  defp extract_collection_total(%{"totalItems" => total}), do: parse_count(total)
  defp extract_collection_total(%{totalItems: total}), do: parse_count(total)

  defp extract_collection_total(total) when is_integer(total) or is_binary(total),
    do: parse_count(total)

  defp extract_collection_total(_), do: 0

  defp fetch_post_counts_from_html(post_url) when is_binary(post_url) do
    headers = [{"Accept", "text/html,application/xhtml+xml"}, {"User-Agent", "Elektrine/1.0"}]

    case safe_request(:get, post_url, headers, nil, receive_timeout: 5_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        parse_post_counts_from_html(body)

      _ ->
        nil
    end
  end

  defp fetch_post_counts_from_html(_), do: nil

  defp parse_post_counts_from_html(body) when is_binary(body) do
    score = extract_named_capture_integer(body, ~r/class="score"[^>]*>(?<value>[^<]+)</)

    comments =
      extract_named_capture_integer(body, ~r/<h2[^>]*>\s*(?<value>\d+)\s+Comments\s*<\/h2>/i) ||
        extract_named_capture_integer(body, ~r/post_reply_count_text">\s*(?<value>\d+)\s*</i)

    upvotes =
      extract_named_capture_integer(body, ~r/class="score"[^>]*title="(?<value>\d+)\s*,\s*\d+"/)

    downvotes =
      extract_named_capture_integer(body, ~r/class="score"[^>]*title="\d+\s*,\s*(?<value>\d+)"/)

    if is_integer(score) or is_integer(comments) do
      %{
        upvotes: upvotes || max(score || 0, 0),
        downvotes: downvotes || 0,
        score: score || 0,
        comments: comments || 0
      }
    else
      nil
    end
  end

  defp parse_post_counts_from_html(_), do: nil

  defp extract_named_capture_integer(body, regex) when is_binary(body) do
    case Regex.named_captures(regex, body) do
      %{"value" => value} ->
        case Integer.parse(String.trim(value)) do
          {parsed, _} -> parsed
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_named_capture_integer(_, _), do: nil

  defp safe_request(method, url, headers, body, opts) do
    request = Finch.build(method, url, headers, body || "")
    SafeFetch.request(request, Elektrine.Finch, opts)
  end

  defp safe_request_lemmy_api(method, url, headers, body, opts) do
    case safe_request(method, url, headers, body, opts) do
      {:ok, %Finch.Response{status: 404}} ->
        url
        |> fallback_lemmy_api_url()
        |> case do
          nil -> {:ok, %Finch.Response{status: 404, headers: [], body: ""}}
          fallback_url -> safe_request(method, fallback_url, headers, body, opts)
        end

      other ->
        other
    end
  end

  defp fallback_lemmy_api_url(url) when is_binary(url) do
    if String.contains?(url, "/api/v4/") do
      String.replace(url, "/api/v4/", "/api/v3/", global: false)
    else
      nil
    end
  end

  defp fallback_lemmy_api_url(_), do: nil
end
