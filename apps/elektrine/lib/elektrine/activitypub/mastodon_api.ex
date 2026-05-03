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
  def fetch_status_counts(status_url, opts \\ [])

  def fetch_status_counts(status_url, opts) when is_binary(status_url) and is_list(opts) do
    case extract_status_info(status_url) do
      {:ok, domain, status_id} ->
        fetch_from_api(domain, status_id, opts)

      {:search, domain, status_url} ->
        fetch_status_counts_via_search(domain, status_url, opts)

      :error ->
        nil
    end
  end

  def fetch_status_counts(_, _), do: nil

  @doc """
  Fetch counts for a post struct/map, using `activitypub_url` as a fallback when
  `activitypub_id` is not directly addressable by a Mastodon-compatible API.
  """
  def fetch_status_counts_for_post(post, opts \\ []) do
    case status_count_lookup(post) do
      {_result_key, status_url} -> fetch_status_counts(status_url, opts)
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
        if misskey_note_url?(status_url) do
          fetch_misskey_context(domain, status_id, status_url, opts)
        else
          fetch_context_from_api(domain, status_id, status_url, opts)
        end

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
  def fetch_favourited_by(status_url, limit_or_opts \\ 40, opts \\ [])

  def fetch_favourited_by(status_url, opts, []) when is_list(opts),
    do: fetch_favourited_by(status_url, 40, opts)

  def fetch_favourited_by(status_url, limit, opts)
      when is_binary(status_url) and is_integer(limit) and is_list(opts) do
    cond do
      misskey_note_url?(status_url) ->
        case extract_status_info(status_url) do
          {:ok, domain, note_id} -> fetch_misskey_reactions(domain, note_id, limit, opts)
          _ -> {:error, :invalid_url}
        end

      true ->
        case status_endpoint_lookup(status_url, opts) do
          {:ok, domain, status_id} ->
            api_url =
              "https://#{domain}/api/v1/statuses/#{status_id}/favourited_by?limit=#{limit}"

            fetch_account_list(api_url, opts)

          {:error, _reason} ->
            {:error, :invalid_url}
        end
    end
  end

  def fetch_favourited_by(_, _, _), do: {:error, :invalid_url}

  @doc """
  Fetch who favourited a post struct/map, using `activitypub_url` as a fallback
  when the canonical `activitypub_id` needs display/status URL resolution.
  """
  def fetch_favourited_by_for_post(post, limit_or_opts \\ 40, opts \\ [])

  def fetch_favourited_by_for_post(post, opts, []) when is_list(opts),
    do: fetch_favourited_by_for_post(post, 40, opts)

  def fetch_favourited_by_for_post(post, limit, opts)
      when is_integer(limit) and is_list(opts) do
    case status_interaction_lookup(post) do
      {_result_key, status_url} -> fetch_favourited_by(status_url, limit, opts)
      nil -> {:error, :invalid_url}
    end
  end

  @doc """
  Fetch who reblogged a status (boosters).
  Returns a list of account info maps.
  """
  def fetch_reblogged_by(status_url, limit_or_opts \\ 40, opts \\ [])

  def fetch_reblogged_by(status_url, opts, []) when is_list(opts),
    do: fetch_reblogged_by(status_url, 40, opts)

  def fetch_reblogged_by(status_url, limit, opts)
      when is_binary(status_url) and is_integer(limit) and is_list(opts) do
    cond do
      misskey_note_url?(status_url) ->
        case extract_status_info(status_url) do
          {:ok, domain, note_id} -> fetch_misskey_renotes(domain, note_id, limit, opts)
          _ -> {:error, :invalid_url}
        end

      true ->
        case status_endpoint_lookup(status_url, opts) do
          {:ok, domain, status_id} ->
            api_url = "https://#{domain}/api/v1/statuses/#{status_id}/reblogged_by?limit=#{limit}"
            fetch_account_list(api_url, opts)

          {:error, _reason} ->
            {:error, :invalid_url}
        end
    end
  end

  def fetch_reblogged_by(_, _, _), do: {:error, :invalid_url}

  @doc """
  Fetch who reblogged a post struct/map, using `activitypub_url` as a fallback
  when the canonical `activitypub_id` needs display/status URL resolution.
  """
  def fetch_reblogged_by_for_post(post, limit_or_opts \\ 40, opts \\ [])

  def fetch_reblogged_by_for_post(post, opts, []) when is_list(opts),
    do: fetch_reblogged_by_for_post(post, 40, opts)

  def fetch_reblogged_by_for_post(post, limit, opts)
      when is_integer(limit) and is_list(opts) do
    case status_interaction_lookup(post) do
      {_result_key, status_url} -> fetch_reblogged_by(status_url, limit, opts)
      nil -> {:error, :invalid_url}
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
      String.match?(url, ~r{/notice/[a-zA-Z0-9_-]+(?:$|[/?#])}) -> :pleroma
      String.match?(url, ~r{/notes/[a-zA-Z0-9]+(?:$|[/?#])}) -> :misskey
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

      # Pleroma/Akkoma display URL: /notice/{id}
      match = Regex.run(~r{https?://([^/]+)/notice/([a-zA-Z0-9_-]+)(?:$|[/?#])}, url) ->
        [_, domain, status_id] = match
        {:ok, domain, status_id}

      # Misskey/Calckey: /notes/{id} - need to use their API
      match = Regex.run(~r{https?://([^/]+)/notes/([a-zA-Z0-9]+)(?:$|[/?#])}, url) ->
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

  defp status_interaction_lookup(post) do
    status_url =
      post
      |> status_url_candidates()
      |> Enum.find(&(mastodon_compatible_url?(&1) || misskey_note_url?(&1)))

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

  defp misskey_note_url?(url) when is_binary(url),
    do: String.match?(url, ~r{/notes/[a-zA-Z0-9]+(?:$|[/?#])})

  defp misskey_note_url?(_), do: false

  defp direct_count_api_url?(url) when is_binary(url) do
    String.match?(url, ~r{/users/[^/]+/statuses/[a-zA-Z0-9_-]+(?:$|[/?#])}) ||
      String.match?(url, ~r{/@[^/]+/[a-zA-Z0-9_-]+(?:$|[/?#])}) ||
      String.match?(url, ~r{/notice/[a-zA-Z0-9_-]+(?:$|[/?#])}) ||
      String.match?(url, ~r{/notes/[a-zA-Z0-9]+(?:$|[/?#])}) ||
      String.match?(url, ~r{/p/[^/]+/\d+(?:$|[/?#])})
  end

  defp direct_count_api_url?(_), do: false

  defp status_endpoint_lookup(status_url, opts) do
    case extract_status_info(status_url) do
      {:ok, domain, status_id} ->
        {:ok, domain, status_id}

      {:search, domain, search_url} ->
        case fetch_status_via_search(domain, search_url, opts) do
          {:ok, %{"id" => status_id}} when is_binary(status_id) and status_id != "" ->
            {:ok, domain, status_id}

          _ ->
            {:error, :invalid_url}
        end

      :error ->
        {:error, :invalid_url}
    end
  end

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

  defp fetch_status_counts_via_search(domain, status_url, opts) do
    case fetch_status_via_search(domain, status_url, opts) do
      {:ok, status} -> status_counts(status)
      {:error, _reason} -> nil
    end
  end

  defp fetch_status_via_search(domain, status_url, opts) do
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
        parse_search_status_response(body)

      {:ok, %Finch.Response{status: _status}} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  defp fetch_from_api(domain, status_id, opts) do
    # Try Mastodon API first
    api_url = "https://#{domain}/api/v1/statuses/#{status_id}"
    headers = build_headers()

    case safe_request(:get, api_url, headers, nil, Keyword.merge([receive_timeout: 5_000], opts)) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        parse_status_response(body)

      {:ok, %Finch.Response{status: 404}} ->
        # Maybe it's a Misskey instance - try their API
        try_misskey_api(domain, status_id, opts)

      {:ok, %Finch.Response{status: _status}} ->
        nil

      {:error, _reason} ->
        nil
    end
  end

  defp try_misskey_api(domain, note_id, opts) do
    # Misskey uses POST for their API
    case fetch_misskey_note(domain, note_id, opts) do
      {:ok, note} -> misskey_status_counts(note)
      {:error, _reason} -> nil
    end
  end

  defp fetch_misskey_note(domain, note_id, opts) do
    misskey_post(domain, "/api/notes/show", %{"noteId" => note_id}, opts, receive_timeout: 5_000)
  end

  defp fetch_misskey_reactions(domain, note_id, limit, opts) do
    case misskey_post(
           domain,
           "/api/notes/reactions",
           %{"noteId" => note_id, "limit" => limit},
           opts,
           receive_timeout: 5_000
         ) do
      {:ok, reactions} when is_list(reactions) ->
        {:ok,
         reactions
         |> Enum.map(&misskey_reaction_account/1)
         |> Enum.reject(&is_nil/1)}

      {:ok, _} ->
        {:error, :parse_error}

      error ->
        error
    end
  end

  defp fetch_misskey_renotes(domain, note_id, limit, opts) do
    case misskey_post(
           domain,
           "/api/notes/renotes",
           %{"noteId" => note_id, "limit" => limit},
           opts,
           receive_timeout: 5_000
         ) do
      {:ok, renotes} when is_list(renotes) ->
        {:ok,
         renotes
         |> Enum.map(&misskey_renote_account/1)
         |> Enum.reject(&is_nil/1)}

      {:ok, _} ->
        {:error, :parse_error}

      error ->
        error
    end
  end

  defp fetch_misskey_context(domain, note_id, root_status_url, opts) do
    case misskey_post(
           domain,
           "/api/notes/children",
           %{"noteId" => note_id, "limit" => 100, "depth" => 12},
           opts,
           receive_timeout: 10_000
         ) do
      {:ok, children} when is_list(children) ->
        {:ok,
         children
         |> Enum.map(&misskey_note_context_status(&1, domain, note_id, root_status_url))
         |> Enum.reject(&is_nil/1)}

      {:ok, _} ->
        {:error, :parse_error}

      error ->
        error
    end
  end

  defp misskey_post(domain, path, payload, opts, request_opts) do
    api_url = "https://#{domain}#{path}"
    headers = [{"Content-Type", "application/json"} | build_headers()]
    body = Jason.encode!(payload)

    case safe_request(:post, api_url, headers, body, Keyword.merge(request_opts, opts)) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        Jason.decode(response_body)

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_status_response(body) do
    case Jason.decode(body) do
      {:ok, status} ->
        status_counts(status)

      _ ->
        nil
    end
  end

  defp parse_search_status_response(body) do
    case Jason.decode(body) do
      {:ok, %{"statuses" => [%{} = status | _]}} -> {:ok, status}
      _ -> {:error, :parse_error}
    end
  end

  defp status_counts(status) when is_map(status) do
    %{
      favourites_count: status["favourites_count"] || 0,
      reblogs_count: status["reblogs_count"] || 0,
      replies_count: status["replies_count"] || 0,
      quotes_count: status["quotes_count"] || get_in(status, ["pleroma", "quotes_count"]) || 0,
      status_metadata: status_metadata(status)
    }
  end

  defp misskey_status_counts(note) when is_map(note) do
    reaction_count =
      [
        nonnegative_count(note["reactionCount"]),
        misskey_reaction_total(note["reactions"])
      ]
      |> Enum.max(fn -> 0 end)

    %{
      favourites_count: reaction_count + nonnegative_count(note["likeCount"]),
      reblogs_count: nonnegative_count(note["renoteCount"]),
      replies_count: nonnegative_count(note["repliesCount"]),
      quotes_count: misskey_quote_count(note),
      status_metadata: misskey_status_metadata(note)
    }
  end

  defp status_metadata(status) when is_map(status) do
    %{}
    |> maybe_put_metadata(
      "emoji_reactions",
      status["emoji_reactions"] || get_in(status, ["pleroma", "emoji_reactions"])
    )
    |> maybe_put_metadata("quotes_count", status["quotes_count"])
    |> maybe_put_metadata("quote", get_in(status, ["pleroma", "quote"]) || status["quote"])
    |> maybe_put_metadata(
      "quote_id",
      get_in(status, ["pleroma", "quote_id"]) || status["quote_id"]
    )
    |> maybe_put_metadata(
      "quote_url",
      get_in(status, ["pleroma", "quote_url"]) || status["quote_url"]
    )
    |> maybe_put_metadata("card", status["card"])
    |> maybe_put_metadata("application", status["application"])
    |> maybe_put_metadata("language", status["language"])
    |> maybe_put_metadata("media_attachments", status["media_attachments"])
    |> maybe_put_metadata("pleroma", status["pleroma"])
  end

  defp misskey_status_metadata(note) when is_map(note) do
    %{}
    |> maybe_put_metadata("emoji_reactions", misskey_emoji_reactions(note["reactions"]))
    |> maybe_put_metadata("quotes_count", positive_metadata_count(misskey_quote_count(note)))
    |> maybe_put_metadata("quote", note["renote"])
    |> maybe_put_metadata("quote_id", note["renoteId"] || get_in(note, ["renote", "id"]))
    |> maybe_put_metadata(
      "quote_url",
      note["renoteUri"] || note["renoteUrl"] || misskey_note_url(note["renote"])
    )
    |> maybe_put_metadata("card", note["cw"] && %{"title" => note["cw"]})
    |> maybe_put_metadata("application", misskey_application(note))
    |> maybe_put_metadata("language", note["lang"] || note["language"])
    |> maybe_put_metadata("media_attachments", misskey_media_attachments(note["files"]))
    |> maybe_put_metadata("misskey", misskey_note_metadata(note))
  end

  defp misskey_emoji_reactions(reactions) when is_map(reactions) do
    reactions
    |> Enum.map(fn {emoji, count} ->
      %{"name" => emoji, "count" => nonnegative_count(count)}
    end)
    |> Enum.filter(&(&1["count"] > 0))
  end

  defp misskey_emoji_reactions(_), do: []

  defp misskey_reaction_total(reactions) when is_map(reactions) do
    Enum.reduce(reactions, 0, fn {_emoji, count}, total -> total + nonnegative_count(count) end)
  end

  defp misskey_reaction_total(_), do: 0

  defp misskey_quote_count(note) when is_map(note) do
    nonnegative_count(note["quoteCount"] || note["quotesCount"] || note["quotedCount"])
  end

  defp misskey_application(%{"app" => %{} = app}), do: app
  defp misskey_application(%{"viaMobile" => true}), do: %{"name" => "Misskey Mobile"}
  defp misskey_application(_), do: nil

  defp misskey_note_metadata(note) when is_map(note) do
    note
    |> Map.take([
      "id",
      "createdAt",
      "cw",
      "visibility",
      "reactionAcceptance",
      "reactionCount",
      "reactions",
      "renoteCount",
      "repliesCount",
      "renoteId",
      "replyId",
      "uri",
      "url"
    ])
  end

  defp misskey_media_attachments(files) when is_list(files) do
    files
    |> Enum.map(&misskey_media_attachment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp misskey_media_attachments(_), do: []

  defp misskey_media_attachment(%{} = file) do
    url = file["url"] || file["uri"] || file["thumbnailUrl"]

    if is_binary(url) and url != "" do
      %{
        "id" => to_string(file["id"] || ""),
        "type" => misskey_media_type(file, url),
        "url" => url,
        "preview_url" => file["thumbnailUrl"] || file["sensitiveThumbnailUrl"] || url,
        "remote_url" => file["uri"] || url,
        "meta" => file["properties"] || %{},
        "description" => file["comment"] || file["name"],
        "blurhash" => file["blurhash"]
      }
    end
  end

  defp misskey_media_attachment(_), do: nil

  defp misskey_media_type(file, url) do
    media_type = String.downcase(to_string(file["type"] || file["mimeType"] || ""))
    url_downcased = String.downcase(url)

    cond do
      String.starts_with?(media_type, "video/") -> "video"
      String.starts_with?(media_type, "audio/") -> "audio"
      String.starts_with?(media_type, "image/gif") -> "gifv"
      String.starts_with?(media_type, "image/") -> "image"
      String.match?(url_downcased, ~r/\.(mp4|webm|ogv|mov)(\?.*)?$/) -> "video"
      String.match?(url_downcased, ~r/\.(mp3|wav|ogg|m4a|flac)(\?.*)?$/) -> "audio"
      String.match?(url_downcased, ~r/\.gif(\?.*)?$/) -> "gifv"
      true -> "unknown"
    end
  end

  defp positive_metadata_count(count) when is_integer(count) and count > 0, do: count
  defp positive_metadata_count(_), do: nil

  defp misskey_reaction_account(%{"user" => user}) when is_map(user),
    do: extract_account_info(user)

  defp misskey_reaction_account(%{"userId" => user_id}) when is_binary(user_id),
    do: %{id: user_id}

  defp misskey_reaction_account(_), do: nil

  defp misskey_renote_account(%{"user" => user}) when is_map(user), do: extract_account_info(user)
  defp misskey_renote_account(_), do: nil

  defp misskey_note_context_status(note, domain, root_note_id, root_status_url)
       when is_map(note) do
    counts = misskey_status_counts(note)
    note_id = normalize_status_id(note["id"])
    reply_id = normalize_status_id(note["replyId"])
    note_url = misskey_note_url(note) || if(note_id, do: "https://#{domain}/notes/#{note_id}")

    %{
      id: note_id,
      uri: note["uri"] || note_url,
      url: note_url,
      content: misskey_note_content(note),
      account: extract_account_info(note["user"]),
      favourites_count: counts.favourites_count,
      reblogs_count: counts.reblogs_count,
      replies_count: counts.replies_count,
      created_at: note["createdAt"],
      in_reply_to_id: reply_id,
      in_reply_to_uri:
        cond do
          reply_id == normalize_status_id(root_note_id) -> root_status_url
          is_binary(reply_id) -> "https://#{domain}/notes/#{reply_id}"
          true -> nil
        end
    }
  end

  defp misskey_note_context_status(_note, _domain, _root_note_id, _root_status_url), do: nil

  defp misskey_note_content(note) when is_map(note) do
    note["text"] || note["cw"] || ""
  end

  defp misskey_note_url(note) when is_map(note) do
    note["url"] || note["uri"] || note["href"]
  end

  defp misskey_note_url(_), do: nil

  defp nonnegative_count(value) when is_integer(value), do: max(value, 0)

  defp nonnegative_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, _} -> max(count, 0)
      :error -> 0
    end
  end

  defp nonnegative_count(_), do: 0

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, _key, []), do: metadata
  defp maybe_put_metadata(metadata, _key, %{} = value) when map_size(value) == 0, do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp fetch_account_list(api_url, opts) do
    headers = build_headers()

    case safe_request(:get, api_url, headers, nil, Keyword.merge([receive_timeout: 5_000], opts)) do
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
    username = account["username"]
    host = account["host"] || account["domain"]

    %{
      id: account["id"],
      username: username,
      acct: account["acct"] || misskey_acct(username, host),
      display_name: account["display_name"] || account["name"],
      url: account["url"] || account["uri"],
      uri: account["uri"] || account["url"],
      avatar: account["avatar"] || account["avatarUrl"]
    }
  end

  defp extract_account_info(_), do: nil

  defp misskey_acct(username, host) when is_binary(username) and is_binary(host) and host != "",
    do: "#{username}@#{host}"

  defp misskey_acct(username, _host), do: username

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
