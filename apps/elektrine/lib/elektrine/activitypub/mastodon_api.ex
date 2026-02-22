defmodule Elektrine.ActivityPub.MastodonApi do
  @moduledoc """
  Helper module for fetching data from Mastodon-compatible instances via their API.

  Supports Mastodon, Pleroma, Akkoma, Misskey (partial), and other compatible servers.
  Uses the Mastodon API v1 endpoints which are widely supported across the fediverse.
  """

  require Logger

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

      :error ->
        nil
    end
  end

  def fetch_status_counts(_), do: nil

  @doc """
  Fetch counts for multiple statuses in parallel.
  Returns a map of activitypub_id => counts.
  Uses yield_many to avoid blocking on slow/failed requests.
  """
  def fetch_statuses_counts(posts) when is_list(posts) do
    tasks =
      posts
      |> Enum.filter(&mastodon_compatible?/1)
      |> Enum.map(fn post ->
        Task.async(fn ->
          activitypub_id = get_activitypub_id(post)
          counts = fetch_status_counts(activitypub_id)
          {activitypub_id, counts}
        end)
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
  def fetch_status_context(status_url) when is_binary(status_url) do
    case extract_status_info(status_url) do
      {:ok, domain, status_id} ->
        api_url = "https://#{domain}/api/v1/statuses/#{status_id}/context"
        headers = build_headers()

        case Finch.build(:get, api_url, headers)
             |> Finch.request(Elektrine.Finch, receive_timeout: 10_000) do
          {:ok, %Finch.Response{status: 200, body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"descendants" => descendants} = context} ->
                ancestors = context["ancestors"] || []

                # Mastodon context returns local status IDs in `in_reply_to_id`. Build a
                # lookup map so we can expose ActivityPub URIs for reply threading.
                id_to_uri_map =
                  build_status_id_to_uri_map(status_id, status_url, ancestors, descendants)

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
                       if(parent_id, do: Map.get(id_to_uri_map, parent_id, status_url), else: nil)
                   }
                 end)}

              _ ->
                {:error, :parse_error}
            end

          {:ok, %Finch.Response{status: status}} ->
            {:error, {:http_error, status}}

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:error, :invalid_url}
    end
  end

  def fetch_status_context(_), do: {:error, :invalid_url}

  @doc """
  Fetch who favourited a status (likers).
  Returns a list of account info maps.
  """
  def fetch_favourited_by(status_url, limit \\ 40) when is_binary(status_url) do
    case extract_status_info(status_url) do
      {:ok, domain, status_id} ->
        api_url = "https://#{domain}/api/v1/statuses/#{status_id}/favourited_by?limit=#{limit}"
        fetch_account_list(api_url)

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

      :error ->
        {:error, :invalid_url}
    end
  end

  @doc """
  Detect if a URL is from a Mastodon-compatible instance.
  This is a heuristic based on URL patterns.
  """
  def mastodon_compatible?(post) do
    activitypub_id = get_activitypub_id(post)

    cond do
      is_nil(activitypub_id) ->
        false

      # Lemmy posts have /post/ pattern - not Mastodon
      String.contains?(activitypub_id, "/post/") ->
        false

      # Lemmy comments have /comment/ pattern
      String.contains?(activitypub_id, "/comment/") ->
        false

      # Mastodon/Pleroma/Akkoma pattern: /users/{user}/statuses/{id}
      String.match?(activitypub_id, ~r{/users/[^/]+/statuses/\d+}) ->
        true

      # Misskey/Calckey pattern: /notes/{id}
      String.match?(activitypub_id, ~r{/notes/[a-zA-Z0-9]+$}) ->
        true

      # Pixelfed pattern: /p/{user}/{id}
      String.match?(activitypub_id, ~r{/p/[^/]+/\d+$}) ->
        true

      # GoToSocial pattern: /users/{user}/statuses/{id}
      String.match?(activitypub_id, ~r{/users/[^/]+/statuses/[A-Z0-9]+$}i) ->
        true

      # Friendica pattern: /objects/{uuid}
      String.match?(activitypub_id, ~r{/objects/[a-f0-9-]+$}i) ->
        true

      # Generic: try if it has a recognizable domain
      true ->
        false
    end
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

      true ->
        :error
    end
  end

  defp build_status_id_to_uri_map(root_status_id, root_status_url, ancestors, descendants) do
    root_id = normalize_status_id(root_status_id)

    statuses =
      ([%{"id" => root_id, "uri" => root_status_url}] ++ ancestors ++ descendants)
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

    case Finch.build(:get, api_url, headers)
         |> Finch.request(Elektrine.Finch, receive_timeout: 5_000) do
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

    case Finch.build(:post, api_url, headers, body)
         |> Finch.request(Elektrine.Finch, receive_timeout: 5_000) do
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

    case Finch.build(:get, api_url, headers)
         |> Finch.request(Elektrine.Finch, receive_timeout: 5_000) do
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
      avatar: account["avatar"]
    }
  end

  defp extract_account_info(_), do: nil

  defp build_headers do
    [
      {"Accept", "application/json"},
      {"User-Agent", "Elektrine/1.0 (ActivityPub; +https://elektrine.com)"}
    ]
  end

  defp get_activitypub_id(%{activitypub_id: id}) when is_binary(id), do: id
  defp get_activitypub_id(%{"id" => id}) when is_binary(id), do: id
  defp get_activitypub_id(_), do: nil
end
