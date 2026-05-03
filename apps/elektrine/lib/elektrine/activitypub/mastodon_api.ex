defmodule Elektrine.ActivityPub.MastodonApi do
  @moduledoc """
  Helper module for fetching data from Mastodon-compatible instances via their API.

  Supports Mastodon, Pleroma, Akkoma, Misskey (partial), and other compatible servers.
  Uses the Mastodon API v1 endpoints which are widely supported across the fediverse.
  """

  require Logger
  alias Elektrine.Domains
  alias Elektrine.HTTP.SafeFetch

  @doc """
  Fetch status counts (favourites, reblogs, replies) from a Mastodon-compatible instance.
  Returns nil if the status is not from a compatible instance or if the fetch fails.

  ## Examples

      iex> fetch_status_counts("https://mastodon.social/users/user/statuses/123456789")
      %{favourites_count: 42, reblogs_count: 10, replies_count: 5}

      iex> fetch_status_counts("https://example.com/not-a-status")
      nil
  """
  def fetch_status_counts(status_url) when is_binary(status_url) do
    case extract_status_info(status_url) do
      {:ok, domain, status_id} ->
        fetch_from_api(domain, status_id)

      {:search, _domain, _status_url} ->
        nil

      :error ->
        nil
    end
  end

  def fetch_status_counts(_), do: nil

  @doc """
  Fetch counts for a post struct/map, using `activitypub_url` as a fallback when
  `activitypub_id` is not directly addressable by a Mastodon-compatible API.
  """
  def fetch_status_counts_for_post(post) do
    case status_count_lookup(post) do
      {_result_key, status_url} -> fetch_status_counts(status_url)
      nil -> nil
    end
  end

  @doc """
  Fetch counts for multiple statuses in parallel.
  Returns a map of activitypub_id => counts.
  Uses yield_many to avoid blocking on slow/failed requests.
  """
  def fetch_statuses_counts(posts) when is_list(posts) do
    tasks =
      posts
      |> Enum.flat_map(fn post ->
        case status_count_lookup(post) do
          {result_key, status_url} ->
            [
              Task.async(fn ->
                counts = fetch_status_counts(status_url)
                {result_key, counts}
              end)
            ]

          nil ->
            []
        end
      end)

    # Use yield_many with 5s timeout - accept whatever completes in time
    results = Task.yield_many(tasks, timeout: 5_000)

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
  Fetch replies to a status from a Mastodon-compatible instance.
  Returns a list of reply statuses with their counts.
  """
  def fetch_status_context(status_url, opts \\ [])

  def fetch_status_context(status_url, opts) when is_binary(status_url) and is_list(opts) do
    case extract_status_info(status_url) do
      {:ok, domain, status_id} ->
        fetch_context_from_api(domain, status_id, status_url, opts)

      {:search, domain, search_url} ->
        fetch_status_context_via_search(domain, search_url, opts)

      :error ->
        {:error, :invalid_url}
    end
  end

  def fetch_status_context(_, _), do: {:error, :invalid_url}

  @doc """
  Fetch who favourited a status (likers).
  Returns a list of account info maps.
  """
  def fetch_favourited_by(status_url, limit \\ 40) when is_binary(status_url) do
    case extract_status_info(status_url) do
      {:ok, domain, status_id} ->
        api_url = "https://#{domain}/api/v1/statuses/#{status_id}/favourited_by?limit=#{limit}"
        fetch_account_list(api_url)

      {:search, _domain, _status_url} ->
        {:error, :invalid_url}

      :error ->
        {:error, :invalid_url}
    end
  end

  @doc """
  Fetch who reblogged a status (boosters).
  Returns a list of account info maps.
  """
  def fetch_reblogged_by(status_url, limit \\ 40) when is_binary(status_url) do
    case extract_status_info(status_url) do
      {:ok, domain, status_id} ->
        api_url = "https://#{domain}/api/v1/statuses/#{status_id}/reblogged_by?limit=#{limit}"
        fetch_account_list(api_url)

      {:search, _domain, _status_url} ->
        {:error, :invalid_url}

      :error ->
        {:error, :invalid_url}
    end
  end

  @doc """
  Detect if a post can use the counts API in this module.
  This includes Misskey note URLs because count lookup falls back to `/api/notes/show`.
  """
  def count_api_compatible?(post) do
    post
    |> status_url_candidates()
    |> Enum.any?(&count_api_compatible_url?/1)
  end

  @doc """
  Detect if a post can use Mastodon-compatible status endpoints like
  `/api/v1/statuses/:id`, `/context`, `/favourited_by`, and `/reblogged_by`.
  """
  def mastodon_compatible?(post) do
    post
    |> status_url_candidates()
    |> Enum.any?(&mastodon_compatible_url?/1)
  end

  @doc """
  Get the software type of an instance based on nodeinfo or URL patterns.
  Returns :mastodon, :pleroma, :akkoma, :misskey, :pixelfed, :gotosocial, :friendica, or :unknown
  """
  def detect_instance_type(url) when is_binary(url) do
    cond do
      String.match?(url, ~r{/users/[^/]+/statuses/\d+}) -> :mastodon_like
      String.match?(url, ~r{/notes/[a-zA-Z0-9]+$}) -> :misskey
      String.match?(url, ~r{/p/[^/]+/\d+$}) -> :pixelfed
      String.match?(url, ~r{/objects/[a-f0-9-]+$}i) -> :friendica
      true -> :unknown
    end
  end

  # Private functions

  defp extract_status_info(url) do
    cond do
      # Mastodon/Pleroma/Akkoma/GoToSocial: /users/{user}/statuses/{id}
      match = Regex.run(~r{https?://([^/]+)/users/[^/]+/statuses/([a-zA-Z0-9_-]+)}, url) ->
        [_, domain, status_id] = match
        {:ok, domain, status_id}

      # Mastodon display URL: /@{user}/{id}
      match = Regex.run(~r{https?://([^/]+)/@[^/]+/([a-zA-Z0-9_-]+)}, url) ->
        [_, domain, status_id] = match
        {:ok, domain, status_id}

      # Misskey/Calckey: /notes/{id} - need to use their API
      match = Regex.run(~r{https?://([^/]+)/notes/([a-zA-Z0-9]+)$}, url) ->
        [_, domain, note_id] = match
        {:ok, domain, note_id}

      # Pixelfed: /p/{user}/{id}
      match = Regex.run(~r{https?://([^/]+)/p/[^/]+/(\d+)$}, url) ->
        [_, domain, status_id] = match
        {:ok, domain, status_id}

      # Pleroma/Akkoma/Friendica object URLs need API search to resolve an internal status ID.
      match = Regex.run(~r{https?://([^/]+)/objects/[a-f0-9-]+$}i, url) ->
        [_, domain] = match
        {:search, domain, url}

      true ->
        :error
    end
  end

  defp status_count_lookup(post) do
    candidates = status_url_candidates(post)

    status_url =
      Enum.find(candidates, &direct_count_api_url?/1) ||
        Enum.find(candidates, &count_api_compatible_url?/1)

    if status_url do
      {get_activitypub_id(post) || status_url, status_url}
    end
  end

  defp status_url_candidates(post) do
    [get_activitypub_id(post), get_activitypub_url(post)]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp count_api_compatible_url?(url) when is_binary(url) do
    cond do
      # Lemmy posts/comments are handled by LemmyApi, not Mastodon-compatible APIs.
      String.contains?(url, "/post/") -> false
      String.contains?(url, "/comment/") -> false
      direct_count_api_url?(url) -> true
      # Friendica/Akkoma object URLs may still be resolvable by API search paths.
      String.match?(url, ~r{/objects/[a-f0-9-]+(?:$|[/?#])}i) -> true
      true -> false
    end
  end

  defp count_api_compatible_url?(_), do: false

  defp mastodon_compatible_url?(url) when is_binary(url) do
    count_api_compatible_url?(url) && !String.match?(url, ~r{/notes/[a-zA-Z0-9]+(?:$|[/?#])})
  end

  defp mastodon_compatible_url?(_), do: false

  defp direct_count_api_url?(url) when is_binary(url) do
    String.match?(url, ~r{/users/[^/]+/statuses/[a-zA-Z0-9_-]+(?:$|[/?#])}) ||
      String.match?(url, ~r{/@[^/]+/[a-zA-Z0-9_-]+(?:$|[/?#])}) ||
      String.match?(url, ~r{/notes/[a-zA-Z0-9]+(?:$|[/?#])}) ||
      String.match?(url, ~r{/p/[^/]+/\d+(?:$|[/?#])})
  end

  defp direct_count_api_url?(_), do: false

  defp fetch_context_from_api(domain, status_id, root_status_url, opts, root_status \\ nil) do
    api_url = "https://#{domain}/api/v1/statuses/#{status_id}/context"
    headers = build_headers()

    case safe_request(:get, api_url, headers, nil, Keyword.merge([receive_timeout: 10_000], opts)) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"descendants" => descendants} = context} ->
            ancestors = context["ancestors"] || []

            # Mastodon context returns local status IDs in `in_reply_to_id`. Build a
            # lookup map so we can expose ActivityPub URIs for reply threading.
            id_to_uri_map =
              build_status_id_to_uri_map(
                status_id,
                root_status_url,
                ancestors,
                descendants,
                root_status
              )

            {:ok,
             Enum.map(descendants, fn status ->
               parent_id = normalize_status_id(status["in_reply_to_id"])

               %{
                 id: status["id"],
                 uri: status["uri"],
                 url: status["url"],
                 content: status["content"],
                 account: extract_account_info(status["account"]),
                 favourites_count: status["favourites_count"] || 0,
                 reblogs_count: status["reblogs_count"] || 0,
                 replies_count: status["replies_count"] || 0,
                 created_at: status["created_at"],
                 in_reply_to_id: status["in_reply_to_id"],
                 in_reply_to_uri:
                   if(parent_id,
                     do: Map.get(id_to_uri_map, parent_id, root_status_url),
                     else: nil
                   )
               }
             end)}

          _ ->
            {:error, :parse_error}
        end

      {:ok, %Finch.Response{status: 404}} ->
        maybe_fetch_status_context_via_search(domain, root_status_url, opts)

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_fetch_status_context_via_search(domain, status_url, opts) do
    if Keyword.get(opts, :skip_context_search, false) do
      {:error, {:http_error, 404}}
    else
      fetch_status_context_via_search(domain, status_url, opts)
    end
  end

  defp fetch_status_context_via_search(domain, status_url, opts) do
    api_url =
      "https://#{domain}/api/v2/search?q=#{URI.encode_www_form(status_url)}&type=statuses&resolve=true&limit=1"

    case safe_request(
           :get,
           api_url,
           build_headers(),
           nil,
           Keyword.merge([receive_timeout: 15_000], opts)
         ) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"statuses" => [%{"id" => status_id} = root_status | _]}} ->
            root_status_url = root_status["uri"] || root_status["url"] || status_url

            fetch_context_from_api(
              domain,
              status_id,
              root_status_url,
              Keyword.put(opts, :skip_context_search, true),
              root_status
            )

          _ ->
            {:error, :not_found}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_status_id_to_uri_map(
         root_status_id,
         root_status_url,
         ancestors,
         descendants,
         root_status
       ) do
    root_id = normalize_status_id(root_status_id)

    statuses =
      ([%{"id" => root_id, "uri" => root_status_url}] ++
         List.wrap(root_status) ++
         ancestors ++
         descendants)
      |> Enum.filter(&is_map/1)

    Enum.reduce(statuses, %{}, fn status, acc ->
      id = normalize_status_id(status["id"])
      uri = status["uri"] || status["url"]

      if id && is_binary(uri) && uri != "" do
        Map.put(acc, id, uri)
      else
        acc
      end
    end)
  end

  defp normalize_status_id(id) when is_integer(id), do: Integer.to_string(id)
  defp normalize_status_id(id) when is_binary(id), do: id
  defp normalize_status_id(_), do: nil

  defp fetch_from_api(domain, status_id) do
    # Try Mastodon API first
    api_url = "https://#{domain}/api/v1/statuses/#{status_id}"
    headers = build_headers()

    case safe_request(:get, api_url, headers, nil, receive_timeout: 5_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        parse_status_response(body)

      {:ok, %Finch.Response{status: 404}} ->
        # Maybe it's a Misskey instance - try their API
        try_misskey_api(domain, status_id)

      {:ok, %Finch.Response{status: _status}} ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  defp try_misskey_api(domain, note_id) do
    # Misskey uses POST for their API
    api_url = "https://#{domain}/api/notes/show"
    headers = [{"Content-Type", "application/json"} | build_headers()]
    body = Jason.encode!(%{"noteId" => note_id})

    case safe_request(:post, api_url, headers, body, receive_timeout: 5_000) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, note} ->
            %{
              favourites_count: (note["reactionCount"] || 0) + (note["likeCount"] || 0),
              reblogs_count: note["renoteCount"] || 0,
              replies_count: note["repliesCount"] || 0
            }

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp parse_status_response(body) do
    case Jason.decode(body) do
      {:ok, status} ->
        %{
          favourites_count: status["favourites_count"] || 0,
          reblogs_count: status["reblogs_count"] || 0,
          replies_count: status["replies_count"] || 0
        }

      _ ->
        nil
    end
  end

  defp fetch_account_list(api_url) do
    headers = build_headers()

    case safe_request(:get, api_url, headers, nil, receive_timeout: 5_000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, accounts} when is_list(accounts) ->
            {:ok, Enum.map(accounts, &extract_account_info/1)}

          _ ->
            {:error, :parse_error}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_account_info(account) when is_map(account) do
    %{
      id: account["id"],
      username: account["username"],
      acct: account["acct"],
      display_name: account["display_name"],
      url: account["url"],
      uri: account["uri"] || account["url"],
      avatar: account["avatar"]
    }
  end

  defp extract_account_info(_), do: nil

  defp build_headers do
    [
      {"Accept", "application/json"},
      {"User-Agent", "Elektrine/1.0 (ActivityPub; +#{Domains.public_base_url()})"}
    ]
  end

  defp safe_request(method, url, headers, body, opts) do
    case Keyword.get(opts, :request_fun) do
      request_fun when is_function(request_fun, 5) ->
        request_fun.(method, url, headers, body, opts)

      _ ->
        request = Finch.build(method, url, headers, body || "")
        SafeFetch.request(request, Elektrine.Finch, opts)
    end
  end

  defp get_activitypub_id(%{activitypub_id: id}) when is_binary(id), do: id
  defp get_activitypub_id(%{"activitypub_id" => id}) when is_binary(id), do: id
  defp get_activitypub_id(%{"id" => id}) when is_binary(id), do: id
  defp get_activitypub_id(_), do: nil

  defp get_activitypub_url(%{activitypub_url: url}) when is_binary(url), do: url
  defp get_activitypub_url(%{"activitypub_url" => url}) when is_binary(url), do: url
  defp get_activitypub_url(%{"url" => url}) when is_binary(url), do: url
  defp get_activitypub_url(_), do: nil
end
