defmodule Elektrine.ActivityPub.NodeInfoFetcherWorker do
  @moduledoc """
  Oban worker for fetching and storing NodeInfo metadata from remote instances.

  This worker fetches:
  - NodeInfo (software name, version, user stats, protocols)
  - Favicon

  Jobs are deduplicated by domain to avoid redundant fetches.
  Metadata is refreshed at most once per 24 hours.
  """
  use Oban.Worker,
    queue: :federation_metadata,
    max_attempts: 3,
    unique: [
      keys: [:domain],
      period: :timer.hours(1),
      states: [:available, :scheduled, :executing]
    ]

  require Logger

  alias Elektrine.ActivityPub.{Instance, Instances}
  alias Elektrine.Repo

  @doc """
  Enqueues a job to fetch nodeinfo for a domain, if needed.
  Returns :ok if enqueued or skipped (already up to date).
  """
  def enqueue(domain) when is_binary(domain) do
    domain = normalize_domain(domain)

    case Instances.get_instance(domain) do
      %Instance{} = instance ->
        if Instance.needs_metadata_update?(instance) do
          do_enqueue(domain)
        else
          :ok
        end

      nil ->
        do_enqueue(domain)
    end
  end

  @doc """
  Enqueues a job to fetch nodeinfo for a domain extracted from a URL or URI.
  """
  def enqueue_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        enqueue(host)

      _ ->
        {:error, :invalid_url}
    end
  end

  def enqueue_from_url(%URI{host: host}) when is_binary(host) and host != "" do
    enqueue(host)
  end

  def enqueue_from_url(_), do: {:error, :invalid_url}

  defp do_enqueue(domain) do
    %{domain: domain}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"domain" => domain}}) do
    Logger.debug("[NodeInfoFetcher] Fetching metadata for #{domain}")

    # Check reachability first
    if Instances.reachable?(domain) do
      fetch_and_store_metadata(domain)
    else
      Logger.debug("[NodeInfoFetcher] Skipping unreachable instance #{domain}")
      {:discard, :unreachable}
    end
  end

  defp fetch_and_store_metadata(domain) do
    # Fetch nodeinfo and favicon in parallel
    nodeinfo_task = Task.async(fn -> fetch_nodeinfo(domain) end)
    favicon_task = Task.async(fn -> fetch_favicon(domain) end)

    nodeinfo = Task.await(nodeinfo_task, 10_000)
    favicon = Task.await(favicon_task, 10_000)

    # Get or create instance record
    {:ok, instance} = Instances.get_or_create_instance(domain)

    # Update with metadata
    attrs = %{
      nodeinfo: nodeinfo || %{},
      favicon: favicon,
      metadata_updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case instance
         |> Instance.metadata_changeset(attrs)
         |> Repo.update() do
      {:ok, updated} ->
        software = Instance.software_name(updated)
        Logger.info("[NodeInfoFetcher] Updated #{domain}: software=#{software || "unknown"}")
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[NodeInfoFetcher] Failed to update #{domain}: #{inspect(changeset.errors)}"
        )

        {:error, :update_failed}
    end
  rescue
    e ->
      Logger.warning("[NodeInfoFetcher] Error fetching #{domain}: #{Exception.message(e)}")
      {:error, :fetch_failed}
  end

  defp fetch_nodeinfo(domain) do
    well_known_url = "https://#{domain}/.well-known/nodeinfo"

    with {:ok, %Finch.Response{status: 200, body: body}} <-
           Finch.build(:get, well_known_url, [{"Accept", "application/json"}])
           |> Finch.request(Elektrine.Finch, receive_timeout: 5000),
         {:ok, data} <- Jason.decode(body),
         nodeinfo_url when is_binary(nodeinfo_url) <- get_nodeinfo_url(data),
         {:ok, nodeinfo} <- fetch_nodeinfo_document(nodeinfo_url) do
      nodeinfo
    else
      error ->
        Logger.debug(
          "[NodeInfoFetcher] Failed to fetch nodeinfo for #{domain}: #{inspect(error)}"
        )

        nil
    end
  end

  defp get_nodeinfo_url(%{"links" => links}) when is_list(links) do
    # Prefer 2.1, then 2.0
    Enum.find_value(links, fn
      %{"rel" => rel, "href" => href} when is_binary(href) ->
        if rel in [
             "http://nodeinfo.diaspora.software/ns/schema/2.1",
             "http://nodeinfo.diaspora.software/ns/schema/2.0"
           ] do
          href
        end

      _ ->
        nil
    end)
  end

  defp get_nodeinfo_url(_), do: nil

  defp fetch_nodeinfo_document(url) do
    case Finch.build(:get, url, [{"Accept", "application/json"}])
         |> Finch.request(Elektrine.Finch, receive_timeout: 5000) do
      {:ok, %Finch.Response{status: 200, body: body}} when byte_size(body) < 50_000 ->
        Jason.decode(body)

      {:ok, %Finch.Response{status: 200, body: body}} ->
        Logger.debug("[NodeInfoFetcher] NodeInfo too large: #{byte_size(body)} bytes")
        {:error, :too_large}

      error ->
        error
    end
  end

  defp fetch_favicon(domain) do
    # Try common favicon locations
    urls = [
      "https://#{domain}/favicon.ico",
      "https://#{domain}/favicon.png"
    ]

    # First try to find favicon link in HTML
    case fetch_favicon_from_html(domain) do
      {:ok, favicon_url} ->
        favicon_url

      :not_found ->
        # Fall back to checking common locations
        Enum.find_value(urls, fn url ->
          case Finch.build(:head, url)
               |> Finch.request(Elektrine.Finch, receive_timeout: 3000) do
            {:ok, %Finch.Response{status: status}} when status in 200..299 ->
              url

            _ ->
              nil
          end
        end)
    end
  end

  defp fetch_favicon_from_html(domain) do
    case Finch.build(:get, "https://#{domain}/", [{"Accept", "text/html"}])
         |> Finch.request(Elektrine.Finch, receive_timeout: 5000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case extract_favicon_from_html(body, domain) do
          nil -> :not_found
          url -> {:ok, url}
        end

      _ ->
        :not_found
    end
  end

  defp extract_favicon_from_html(html, domain) do
    # Simple regex to find favicon link - avoid full HTML parsing for performance
    case Regex.run(~r/<link[^>]+rel=["'](?:shortcut )?icon["'][^>]+href=["']([^"']+)["']/i, html) do
      [_, href] ->
        resolve_favicon_url(href, domain)

      nil ->
        # Try alternate order (href before rel)
        case Regex.run(
               ~r/<link[^>]+href=["']([^"']+)["'][^>]+rel=["'](?:shortcut )?icon["']/i,
               html
             ) do
          [_, href] -> resolve_favicon_url(href, domain)
          nil -> nil
        end
    end
  end

  defp resolve_favicon_url(href, domain) do
    cond do
      String.starts_with?(href, "http://") or String.starts_with?(href, "https://") ->
        href

      String.starts_with?(href, "//") ->
        "https:" <> href

      String.starts_with?(href, "/") ->
        "https://#{domain}#{href}"

      true ->
        "https://#{domain}/#{href}"
    end
    |> String.slice(0, 255)
  end

  defp normalize_domain(domain) do
    domain
    |> String.trim()
    |> String.downcase()
  end
end
