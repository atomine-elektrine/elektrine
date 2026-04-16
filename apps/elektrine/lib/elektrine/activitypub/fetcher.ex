defmodule Elektrine.ActivityPub.Fetcher do
  @moduledoc """
  Fetches ActivityPub resources from remote instances using Finch.
  Supports signed fetches for instances requiring authorized fetch mode.
  """

  require Logger

  alias Elektrine.ActivityPub.HTTPSignature
  alias Elektrine.ActivityPub.Instances
  alias Elektrine.HTTP.Backoff
  alias Elektrine.Security.URLValidator

  @max_activitypub_body_bytes 2 * 1024 * 1024

  @doc """
  Fetches an actor document from a remote instance.
  Uses signed fetch if configured.
  Also triggers a background fetch of instance metadata (nodeinfo).
  """
  def fetch_actor(uri, opts \\ []) do
    with :ok <- validate_fetch_url(uri, :actor, opts) do
      # Tests may inject a request function and don't need nodeinfo side effects.
      unless Keyword.has_key?(opts, :request_fun) do
        # Trigger nodeinfo fetch for this instance (async, deduplicated)
        Instances.fetch_metadata_from_url(uri)
      end

      do_signed_fetch(uri, opts)
    end
  end

  @doc """
  Fetches an activity or object from a remote instance.
  Uses signed fetch if configured.
  Results are cached to reduce network load.

  Options:
    - `:skip_cache` - bypass the cache and always fetch fresh (default: false)
    - `:sign` - force signed fetch (default: based on config)
  """
  def fetch_object(uri, opts \\ []) do
    skip_cache = Keyword.get(opts, :skip_cache, false)

    with :ok <- validate_fetch_url(uri, :object, opts) do
      if skip_cache do
        do_signed_fetch(uri, opts)
      else
        Elektrine.AppCache.get_object(uri, fn ->
          do_signed_fetch(uri, opts)
        end)
      end
    end
  end

  @doc """
  Fetches an object without caching. Use when you need fresh data.
  """
  def fetch_object_uncached(uri, opts \\ []) do
    with :ok <- validate_fetch_url(uri, :object, opts) do
      # Also invalidate the cache so next regular fetch gets fresh data
      Elektrine.AppCache.invalidate_object(uri)
      do_signed_fetch(uri, opts)
    end
  end

  # Performs a signed or unsigned fetch based on configuration
  defp do_signed_fetch(uri, opts) do
    base_headers = [
      {"accept",
       "application/activity+json, application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\""},
      {"user-agent", "Elektrine/1.0"}
    ]

    # Check if we should sign the request
    sign_fetches = Keyword.get(opts, :sign, signed_fetches_enabled?())

    headers =
      if sign_fetches do
        case get_instance_signing_key() do
          {:ok, {private_key, key_id}} ->
            # Sign the GET request
            signature_headers = HTTPSignature.sign_get(uri, private_key, key_id)
            base_headers ++ signature_headers

          {:error, _} ->
            # No signing key available, use unsigned request
            base_headers
        end
      else
        base_headers
      end

    case request_with_backoff(uri, headers, request_opts(opts)) do
      {:ok, %Finch.Response{status: 200, body: body}} = response ->
        case Jason.decode(body) do
          {:ok, data} ->
            {:ok, data}

          {:error, reason} ->
            maybe_recover_object_from_html(uri, response, reason, opts)
        end

      {:ok, %Finch.Response{} = response}
      when response.status in [401, 403] and sign_fetches == false ->
        # Instance requires signed fetches - retry with signature
        if cloudflare_blocked_response?(response) do
          maybe_backoff_blocked_host(uri)

          Logger.warning(
            "Cloudflare blocked ActivityPub fetch from #{uri}, skipping signed retry"
          )

          {:error, :fetch_failed}
        else
          Logger.debug("Instance #{uri} requires signed fetch, retrying...")
          do_signed_fetch(uri, Keyword.put(opts, :sign, true))
        end

      {:ok, %Finch.Response{status: status, body: _body}} when status in [404, 410] ->
        case mastodon_status_fallback(uri, opts) do
          {:ok, object_data} ->
            Logger.info("Recovered status document via Mastodon API fallback for #{uri}")
            {:ok, object_data}

          _ ->
            Logger.debug("Object not found or deleted: #{uri}, status: #{status}")
            {:error, :not_found}
        end

      {:ok, %Finch.Response{} = response} ->
        log_failed_fetch(uri, response)

        {:error, :fetch_failed}

      {:error, :backoff} ->
        Logger.debug("Backoff active for #{uri}, deferring fetch")
        {:error, :fetch_failed}

      {:error, reason} ->
        Logger.warning("HTTP error fetching from #{uri}: #{inspect(reason)}")
        {:error, :http_error}
    end
  end

  defp signed_fetches_enabled? do
    Application.get_env(:elektrine, :activitypub, [])
    |> Keyword.get(:sign_fetches, false)
  end

  # Get the instance actor's signing key for signed fetches
  defp get_instance_signing_key do
    # Use the first admin user's key, or create an instance actor
    case get_instance_actor_key() do
      {:ok, _} = result -> result
      {:error, _} -> {:error, :no_signing_key}
    end
  end

  defp get_instance_actor_key do
    # Try to get from the first AP-enabled admin user
    import Ecto.Query

    case Elektrine.Repo.one(
           from(u in Elektrine.Accounts.User,
             where: u.is_admin == true and u.activitypub_enabled == true,
             where: not is_nil(u.activitypub_private_key),
             limit: 1
           )
         ) do
      %{activitypub_private_key: private_key} = user when is_binary(private_key) ->
        key_id = Elektrine.ActivityPub.actor_key_id(user)
        {:ok, {private_key, key_id}}

      _ ->
        {:error, :no_admin_key}
    end
  end

  @doc """
  Resolves a WebFinger URI to an ActivityPub actor URI.
  Results are cached since WebFinger data rarely changes.
  """
  def webfinger_lookup(acct, opts \\ []) do
    if Keyword.get(opts, :skip_cache, false) do
      do_webfinger_lookup(acct, opts)
    else
      Elektrine.AppCache.get_webfinger(acct, fn ->
        do_webfinger_lookup(acct, opts)
      end)
    end
  end

  defp do_webfinger_lookup(acct, opts) do
    # acct format: user@domain.com
    [_username, domain] = String.split(acct, "@", parts: 2)

    webfinger_url = "https://#{domain}/.well-known/webfinger?resource=acct:#{acct}"

    headers = [
      {"accept", "application/jrd+json, application/json"},
      {"user-agent", "Elektrine/1.0"}
    ]

    with :ok <- validate_fetch_url(webfinger_url, :webfinger, opts) do
      case request_with_backoff(webfinger_url, headers, request_opts(opts)) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"links" => links}} ->
              # Find the self link with type application/activity+json
              actor_link =
                Enum.find(links, fn link ->
                  link["rel"] == "self" &&
                    (link["type"] == "application/activity+json" ||
                       link["type"] ==
                         "application/ld+json; profile=\"https://www.w3.org/ns/activitystreams\"")
                end)

              case actor_link do
                %{"href" => href} -> {:ok, href}
                _ -> {:error, :no_actor_link}
              end

            {:error, _} ->
              {:error, :invalid_json}
          end

        {:ok, %Finch.Response{status: status}} ->
          Logger.error("WebFinger lookup failed, status: #{status}")
          {:error, :webfinger_failed}

        {:error, :backoff} ->
          Logger.error("WebFinger lookup deferred due to remote backoff: #{webfinger_url}")
          {:error, :webfinger_failed}

        {:error, reason} ->
          Logger.error("HTTP error during WebFinger: #{inspect(reason)}")
          {:error, :http_error}
      end
    end
  end

  defp request_opts(opts) do
    [recv_timeout: 10_000, timeout: 10_000, max_body_bytes: @max_activitypub_body_bytes]
    |> Keyword.merge(Keyword.take(opts, [:request_fun]))
  end

  defp maybe_recover_object_from_html(
         uri,
         {:ok, %Finch.Response{body: body, headers: response_headers}},
         reason,
         opts
       ) do
    case lemmy_object_fallback(uri, body, response_headers, opts) do
      {:ok, object_data, recovery_type} ->
        Logger.info("Recovered #{recovery_type} document via Lemmy fallback for #{uri}")
        {:ok, object_data}

      _ ->
        Logger.error("Failed to decode JSON from #{uri}: #{inspect(reason)}")
        {:error, :invalid_json}
    end
  end

  defp maybe_recover_object_from_html(_uri, _response, _reason, _opts),
    do: {:error, :invalid_json}

  defp mastodon_status_fallback(uri, opts) when is_binary(uri) do
    with {:ok, domain, username, status_id} <- extract_mastodon_status_info(uri),
         {:ok, status} <- fetch_mastodon_status(domain, status_id, opts),
         {:ok, object} <- normalize_mastodon_status(status, uri, username) do
      {:ok, object}
    else
      _ -> {:error, :no_status_fallback}
    end
  end

  defp mastodon_status_fallback(_, _), do: {:error, :no_status_fallback}

  defp extract_mastodon_status_info(url) when is_binary(url) do
    cond do
      match = Regex.run(~r{https?://([^/]+)/users/([^/]+)/statuses/([a-zA-Z0-9_-]+)}, url) ->
        [_, domain, username, status_id] = match
        {:ok, domain, username, status_id}

      match = Regex.run(~r{https?://([^/]+)/@([^/]+)/([a-zA-Z0-9_-]+)}, url) ->
        [_, domain, username, status_id] = match
        {:ok, domain, username, status_id}

      true ->
        {:error, :unsupported_status_url}
    end
  end

  defp extract_mastodon_status_info(_), do: {:error, :unsupported_status_url}

  defp fetch_mastodon_status(domain, status_id, opts) do
    api_url = "https://#{domain}/api/v1/statuses/#{status_id}"

    headers = [
      {"accept", "application/json"},
      {"user-agent", "Elektrine/1.0"}
    ]

    case request_with_backoff(api_url, headers, request_opts(opts)) do
      {:ok, %Finch.Response{status: 200, body: body}} -> Jason.decode(body)
      _ -> {:error, :status_fetch_failed}
    end
  end

  defp normalize_mastodon_status(%{"account" => _account} = status, requested_uri, username) do
    visibility = Map.get(status, "visibility")

    if visibility in ["public", "unlisted", nil] do
      actor_uri = mastodon_actor_uri(requested_uri, username)

      {:ok,
       %{
         "id" => Map.get(status, "uri") || requested_uri,
         "type" => "Note",
         "content" => Map.get(status, "content") || "",
         "published" => Map.get(status, "created_at"),
         "url" => Map.get(status, "url") || requested_uri,
         "attributedTo" => actor_uri,
         "to" => mastodon_status_to_audience(visibility),
         "cc" => mastodon_status_cc_audience(visibility, actor_uri),
         "sensitive" => Map.get(status, "sensitive") || false,
         "summary" => Map.get(status, "spoiler_text"),
         "attachment" => normalize_mastodon_attachments(Map.get(status, "media_attachments", [])),
         "tag" => []
       }}
    else
      {:error, :unsupported_visibility}
    end
  end

  defp normalize_mastodon_status(_, _, _), do: {:error, :invalid_status}

  defp mastodon_actor_uri(requested_uri, username) do
    case URI.parse(requested_uri) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        "#{scheme}://#{host}/users/#{username}"

      _ ->
        requested_uri
    end
  end

  defp mastodon_status_to_audience("unlisted"), do: []
  defp mastodon_status_to_audience(_), do: ["https://www.w3.org/ns/activitystreams#Public"]

  defp mastodon_status_cc_audience("unlisted", actor_uri), do: [actor_uri <> "/followers"]
  defp mastodon_status_cc_audience(_, _), do: []

  defp normalize_mastodon_attachments(attachments) when is_list(attachments) do
    Enum.map(attachments, fn attachment ->
      %{
        "type" => "Document",
        "mediaType" =>
          attachment["mime_type"] || attachment["type"] || "application/octet-stream",
        "url" => attachment["url"],
        "name" => attachment["description"]
      }
    end)
    |> Enum.filter(&(is_binary(&1["url"]) and &1["url"] != ""))
  end

  defp normalize_mastodon_attachments(_), do: []

  defp lemmy_object_fallback(uri, body, response_headers, opts) do
    if html_response?(body, response_headers) do
      with {:ok, resolve_url, type} <- lemmy_resolve_url(uri),
           {:ok, resolved_body} <- fetch_lemmy_resolved_object(resolve_url, opts),
           {:ok, object_data} <- normalize_lemmy_resolved_object(resolved_body, uri, type) do
        {:ok, object_data, type}
      else
        _ -> {:error, :no_object_fallback}
      end
    else
      {:error, :no_object_fallback}
    end
  end

  defp html_response?(body, response_headers)
       when is_binary(body) and is_list(response_headers) do
    content_type =
      response_headers
      |> Enum.find_value(fn {key, value} ->
        if String.downcase(key) == "content-type", do: String.downcase(value), else: nil
      end)

    is_binary(content_type) && String.contains?(content_type, "text/html") &&
      String.contains?(String.downcase(body), "<!doctype html")
  end

  defp html_response?(_, _), do: false

  defp lemmy_resolve_url(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and is_binary(host) and path in [nil, "", "/"] ->
        {:ok, "#{scheme}://#{host}/api/v4/site", :site}

      %URI{scheme: scheme, host: host, path: "/u/" <> _rest}
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, "#{scheme}://#{host}/api/v4/resolve_object?q=#{URI.encode_www_form(uri)}", :person}

      %URI{scheme: scheme, host: host, path: "/c/" <> _rest}
      when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, "#{scheme}://#{host}/api/v4/resolve_object?q=#{URI.encode_www_form(uri)}", :group}

      %URI{scheme: scheme, host: host, path: "/comment/" <> comment_id}
      when scheme in ["http", "https"] and is_binary(host) ->
        if Regex.match?(~r{^\d+(?:$|/)}, comment_id) do
          {:ok, "#{scheme}://#{host}/api/v4/resolve_object?q=#{URI.encode_www_form(uri)}",
           :comment}
        else
          {:error, :unsupported_actor_path}
        end

      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and is_binary(host) ->
        if Regex.match?(
             ~r{^/(post/\d+|c/[^/]+/p/\d+|m/[^/]+/[pt]/\d+)(?:$|/)},
             String.trim_leading(path, "/") |> then(&("/" <> &1))
           ) do
          {:ok, "#{scheme}://#{host}/api/v4/resolve_object?q=#{URI.encode_www_form(uri)}", :page}
        else
          {:error, :unsupported_actor_path}
        end

      _ ->
        {:error, :unsupported_actor_path}
    end
  end

  defp lemmy_resolve_url(_), do: {:error, :unsupported_actor_path}

  defp fetch_lemmy_resolved_object(resolve_url, opts) do
    headers = [
      {"accept", "application/json"},
      {"user-agent", "Elektrine/1.0"}
    ]

    case request_lemmy_resolve_with_fallback(resolve_url, headers, request_opts(opts)) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        Jason.decode(body)

      _ ->
        {:error, :resolve_failed}
    end
  end

  defp request_lemmy_resolve_with_fallback(resolve_url, headers, opts) do
    case request_with_backoff(resolve_url, headers, opts) do
      {:ok, %Finch.Response{status: 404}} ->
        resolve_url
        |> fallback_lemmy_api_url()
        |> case do
          nil -> {:ok, %Finch.Response{status: 404, headers: [], body: ""}}
          fallback_url -> request_with_backoff(fallback_url, headers, opts)
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

  defp normalize_lemmy_resolved_actor(
         %{"site_view" => %{"site" => site}},
         requested_uri,
         :site
       )
       when is_map(site) do
    actor_id = site["actor_id"] || requested_uri

    preferred_username =
      actor_id
      |> URI.parse()
      |> Map.get(:host)
      |> case do
        host when is_binary(host) and host != "" -> host
        _ -> site["name"] || "instance"
      end

    {:ok,
     %{
       "id" => actor_id,
       "type" => "Application",
       "preferredUsername" => preferred_username,
       "name" => site["name"] || preferred_username,
       "summary" => site["description"],
       "icon" => normalize_lemmy_image(site["icon"]),
       "image" => normalize_lemmy_image(site["banner"]),
       "inbox" => site["inbox_url"] || actor_id <> "/inbox",
       "published" => site["published"],
       "updated" => site["updated"],
       "publicKey" => %{
         "id" => actor_id <> "#main-key",
         "owner" => actor_id,
         "publicKeyPem" => site["public_key"] || unavailable_public_key_pem()
       },
       "endpoints" => %{"sharedInbox" => shared_inbox_for_actor(actor_id)}
     }}
  end

  defp normalize_lemmy_resolved_actor(
         %{"person" => %{"person" => person}},
         requested_uri,
         :person
       )
       when is_map(person) do
    actor_id = person["actor_id"] || requested_uri

    {:ok,
     %{
       "id" => actor_id,
       "type" => "Person",
       "preferredUsername" => person["name"],
       "name" => person["display_name"],
       "summary" => person["bio"],
       "icon" => normalize_lemmy_image(person["avatar"]),
       "image" => normalize_lemmy_image(person["banner"]),
       "inbox" => actor_id <> "/inbox",
       "outbox" => actor_id <> "/outbox",
       "followers" => actor_id <> "/followers",
       "following" => actor_id <> "/following",
       "published" => person["published"],
       "publicKey" => %{
         "id" => actor_id <> "#main-key",
         "owner" => actor_id,
         "publicKeyPem" => unavailable_public_key_pem()
       },
       "endpoints" => %{"sharedInbox" => shared_inbox_for_actor(actor_id)}
     }}
  end

  defp normalize_lemmy_resolved_actor(
         %{"community" => %{"community" => community}},
         requested_uri,
         :group
       )
       when is_map(community) do
    actor_id = community["actor_id"] || requested_uri

    {:ok,
     %{
       "id" => actor_id,
       "type" => "Group",
       "preferredUsername" => community["name"],
       "name" => community["title"] || community["name"],
       "summary" => community["description"],
       "icon" => normalize_lemmy_image(community["icon"]),
       "image" => normalize_lemmy_image(community["banner"]),
       "inbox" => actor_id <> "/inbox",
       "outbox" => actor_id <> "/outbox",
       "followers" => actor_id <> "/followers",
       "published" => community["published"],
       "updated" => community["updated"],
       "publicKey" => %{
         "id" => actor_id <> "#main-key",
         "owner" => actor_id,
         "publicKeyPem" => unavailable_public_key_pem()
       },
       "endpoints" => %{"sharedInbox" => shared_inbox_for_actor(actor_id)}
     }}
  end

  defp normalize_lemmy_resolved_actor(_, _, _), do: {:error, :invalid_resolved_actor}

  defp normalize_lemmy_resolved_object(resolved_body, requested_uri, :person) do
    normalize_lemmy_resolved_actor(resolved_body, requested_uri, :person)
  end

  defp normalize_lemmy_resolved_object(resolved_body, requested_uri, :site) do
    normalize_lemmy_resolved_actor(resolved_body, requested_uri, :site)
  end

  defp normalize_lemmy_resolved_object(resolved_body, requested_uri, :group) do
    normalize_lemmy_resolved_actor(resolved_body, requested_uri, :group)
  end

  defp normalize_lemmy_resolved_object(%{"comment" => comment_view}, requested_uri, :comment)
       when is_map(comment_view) do
    comment = comment_view["comment"] || %{}
    creator = comment_view["creator"] || %{}
    post = comment_view["post"] || %{}
    community = comment_view["community"] || %{}
    counts = comment_view["counts"] || %{}

    object_id = comment["ap_id"] || requested_uri
    post_url = post["ap_id"] || post["url"] || requested_uri
    community_actor_id = community["actor_id"]

    {:ok,
     %{
       "id" => object_id,
       "type" => "Note",
       "url" => object_id,
       "content" => comment["content"] || "",
       "published" => comment["published"],
       "updated" => comment["updated"],
       "attributedTo" => creator["actor_id"],
       "to" => ["https://www.w3.org/ns/activitystreams#Public"],
       "cc" => Enum.reject([community_actor_id], &is_nil/1),
       "inReplyTo" => normalize_lemmy_comment_parent_ref(comment, post_url, requested_uri),
       "likes" => %{"totalItems" => counts["upvotes"] || 0},
       "replies" => %{"type" => "Collection", "totalItems" => counts["child_count"] || 0},
       "shares" => %{"totalItems" => 0},
       "sensitive" => false,
       "_lemmy" => %{
         "community_actor_id" => community_actor_id,
         "creator_name" => creator["name"],
         "creator_avatar" => creator["avatar"],
         "score" => counts["score"] || 0,
         "upvotes" => counts["upvotes"] || 0,
         "downvotes" => counts["downvotes"] || 0,
         "child_count" => counts["child_count"] || 0
       }
     }}
  end

  defp normalize_lemmy_resolved_object(%{"post" => post_view}, requested_uri, :page)
       when is_map(post_view) do
    post = post_view["post"] || %{}
    creator = post_view["creator"] || %{}
    community = post_view["community"] || %{}
    counts = post_view["counts"] || %{}

    object_id = post["ap_id"] || requested_uri
    community_actor_id = community["actor_id"]
    external_url = normalize_external_post_url(post["url"], object_id)
    comment_count = counts["comments"] || 0

    {:ok,
     %{
       "id" => object_id,
       "type" => "Page",
       "url" => external_url || object_id,
       "name" => post["name"],
       "content" => post["body"],
       "published" => post["published"],
       "updated" => post["updated"],
       "attributedTo" => creator["actor_id"],
       "to" => ["https://www.w3.org/ns/activitystreams#Public"],
       "cc" => Enum.reject([community_actor_id], &is_nil/1),
       "sensitive" => post["nsfw"] || false,
       "comments" => %{"type" => "Collection", "totalItems" => comment_count},
       "replies" => %{"type" => "Collection", "totalItems" => comment_count},
       "attachment" => normalize_lemmy_post_attachment(external_url, post["name"]),
       "_lemmy" => %{
         "community_actor_id" => community_actor_id,
         "creator_name" => creator["name"],
         "creator_avatar" => creator["avatar"],
         "score" => counts["score"] || 0,
         "upvotes" => counts["upvotes"] || 0,
         "downvotes" => counts["downvotes"] || 0
       }
     }}
  end

  defp normalize_lemmy_resolved_object(_, _, _), do: {:error, :invalid_resolved_object}

  defp normalize_external_post_url(url, object_id) when is_binary(url) and url != object_id,
    do: url

  defp normalize_external_post_url(_, _), do: nil

  defp normalize_lemmy_comment_parent_ref(comment, post_url, requested_uri)
       when is_map(comment) do
    case comment["path"] do
      path when is_binary(path) ->
        case String.split(path, ".") |> Enum.reverse() do
          [_self, parent_id | _] when parent_id not in [nil, "", "0"] ->
            build_lemmy_comment_uri(requested_uri, parent_id)

          _ ->
            post_url
        end

      _ ->
        post_url
    end
  end

  defp normalize_lemmy_comment_parent_ref(_, post_url, _requested_uri), do: post_url

  defp build_lemmy_comment_uri(requested_uri, comment_id) do
    case URI.parse(requested_uri) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and is_binary(comment_id) ->
        "#{scheme}://#{host}/comment/#{comment_id}"

      _ ->
        requested_uri
    end
  end

  defp normalize_lemmy_post_attachment(url, name) when is_binary(url) do
    [
      %{
        "type" => "Link",
        "href" => url,
        "name" => name || url
      }
    ]
  end

  defp normalize_lemmy_post_attachment(_, _), do: []

  defp normalize_lemmy_image(url) when is_binary(url), do: %{"type" => "Image", "url" => url}
  defp normalize_lemmy_image(_), do: nil

  defp shared_inbox_for_actor(actor_id) when is_binary(actor_id) do
    case URI.parse(actor_id) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        "#{scheme}://#{host}/inbox"

      _ ->
        nil
    end
  end

  defp shared_inbox_for_actor(_), do: nil

  defp unavailable_public_key_pem do
    "-----BEGIN PUBLIC KEY-----\nUNAVAILABLE\n-----END PUBLIC KEY-----"
  end

  defp validate_fetch_url(uri, kind, opts) when is_binary(uri) do
    if Keyword.get(opts, :validate_url, true) do
      case URLValidator.validate(uri) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Blocked unsafe ActivityPub #{kind} URL #{inspect(uri)}: #{inspect(reason)}"
          )

          {:error, :unsafe_url}
      end
    else
      :ok
    end
  end

  defp validate_fetch_url(_uri, _kind, _opts), do: {:error, :unsafe_url}

  defp request_with_backoff(url, headers, opts) do
    request_fun = Keyword.get(opts, :request_fun, &Backoff.get/3)
    request_fun.(url, headers, Keyword.drop(opts, [:request_fun]))
  end

  defp log_failed_fetch(uri, %Finch.Response{} = response) do
    if cloudflare_blocked_response?(response) do
      maybe_backoff_blocked_host(uri)

      Logger.warning(
        "Cloudflare blocked ActivityPub fetch from #{uri} with status #{response.status}"
      )
    else
      Logger.warning(
        "Failed to fetch from #{uri}, status: #{response.status}, body: #{String.slice(response.body || "", 0, 200)}"
      )
    end
  end

  defp cloudflare_blocked_response?(%Finch.Response{status: 403, headers: headers, body: body}) do
    server =
      headers
      |> Enum.find_value(fn {key, value} ->
        if String.downcase(key) == "server", do: String.downcase(value), else: nil
      end)

    body_text = String.downcase(body || "")

    server == "cloudflare" &&
      (String.contains?(body_text, "attention required") ||
         String.contains?(body_text, "sorry, you have been blocked") ||
         String.contains?(body_text, "cloudflare ray id"))
  end

  defp cloudflare_blocked_response?(_), do: false

  defp maybe_backoff_blocked_host(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) and host != "" -> Backoff.set_backoff(host)
      _ -> :ok
    end
  end

  defp maybe_backoff_blocked_host(_), do: :ok
end
