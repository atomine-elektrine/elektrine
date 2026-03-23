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
      Logger.info("Fetching actor from: #{uri}")

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
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, data} ->
            {:ok, data}

          {:error, reason} ->
            Logger.error("Failed to decode JSON from #{uri}: #{inspect(reason)}")
            {:error, :invalid_json}
        end

      {:ok, %Finch.Response{status: status}}
      when status in [401, 403] and sign_fetches == false ->
        # Instance requires signed fetches - retry with signature
        Logger.debug("Instance #{uri} requires signed fetch, retrying...")
        do_signed_fetch(uri, Keyword.put(opts, :sign, true))

      {:ok, %Finch.Response{status: status, body: _body}} when status in [404, 410] ->
        Logger.debug("Object not found or deleted: #{uri}, status: #{status}")
        {:error, :not_found}

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.warning(
          "Failed to fetch from #{uri}, status: #{status}, body: #{String.slice(body || "", 0, 200)}"
        )

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
    [recv_timeout: 5_000, timeout: 5_000, max_body_bytes: @max_activitypub_body_bytes]
    |> Keyword.merge(Keyword.take(opts, [:request_fun]))
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
end
