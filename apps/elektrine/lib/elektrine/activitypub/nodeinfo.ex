defmodule Elektrine.ActivityPub.Nodeinfo do
  @moduledoc """
  Fetches and caches nodeinfo from ActivityPub instances to detect software type.
  """

  use GenServer
  require Logger

  @cache_ttl :timer.hours(24)
  @known_pixelfed_software ["pixelfed"]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{cache: %{}}}
  end

  @doc """
  Check if a domain is running Pixelfed or similar photo-focused software.
  Returns true if the instance is photo-focused.
  """
  def is_photo_instance?(domain) do
    case get_software(domain) do
      {:ok, software} -> String.downcase(software) in @known_pixelfed_software
      _ -> false
    end
  end

  @doc """
  Get the software name for a domain. Caches results.
  """
  def get_software(domain) do
    GenServer.call(__MODULE__, {:get_software, domain}, 10_000)
  catch
    :exit, _ -> {:error, :timeout}
  end

  @doc """
  Batch lookup software for multiple domains. Much faster than calling get_software repeatedly.
  Returns a map of domain => software_name (lowercase).
  Domains that fail to resolve are omitted from the result.
  """
  def get_software_batch(domains) when is_list(domains) do
    domains = Enum.uniq(domains)

    # First, get all cached results in one GenServer call
    {cached, uncached} = GenServer.call(__MODULE__, {:get_batch_cached, domains}, 10_000)

    # Fetch uncached domains in parallel (outside of GenServer)
    fetched =
      if uncached != [] do
        uncached
        |> Task.async_stream(
          fn domain ->
            result = fetch_nodeinfo(domain)
            {domain, result}
          end,
          max_concurrency: 20,
          timeout: 6000,
          on_timeout: :kill_task
        )
        |> Enum.reduce(%{}, fn
          {:ok, {domain, {:ok, software}}}, acc ->
            Map.put(acc, domain, String.downcase(software))

          {:ok, {_domain, {:error, _}}}, acc ->
            acc

          {:exit, _reason}, acc ->
            acc
        end)
      else
        %{}
      end

    # Store fetched results back in cache
    if map_size(fetched) > 0 do
      GenServer.cast(__MODULE__, {:cache_batch, fetched})
    end

    # Also cache failures to avoid repeated lookups
    failed = uncached -- Map.keys(fetched)

    if failed != [] do
      GenServer.cast(__MODULE__, {:cache_failures, failed})
    end

    # Merge cached and fetched results
    Map.merge(cached, fetched)
  catch
    :exit, _ -> %{}
  end

  @impl true
  def handle_call({:get_software, domain}, _from, state) do
    case check_cache(state.cache, domain) do
      {:ok, software} ->
        {:reply, {:ok, software}, state}

      :miss ->
        case fetch_nodeinfo(domain) do
          {:ok, software} ->
            new_cache =
              Map.put(state.cache, domain, {software, System.monotonic_time(:millisecond)})

            {:reply, {:ok, software}, %{state | cache: new_cache}}

          {:error, reason} ->
            # Cache the failure too to avoid repeated requests
            new_cache =
              Map.put(state.cache, domain, {:unknown, System.monotonic_time(:millisecond)})

            {:reply, {:error, reason}, %{state | cache: new_cache}}
        end

      {:error, :unknown} ->
        {:reply, {:error, :unknown}, state}
    end
  end

  @impl true
  def handle_call({:get_batch_cached, domains}, _from, state) do
    # Partition domains into cached (with valid results) and uncached
    {cached_map, uncached} =
      Enum.reduce(domains, {%{}, []}, fn domain, {cached, uncached} ->
        case check_cache(state.cache, domain) do
          {:ok, software} ->
            {Map.put(cached, domain, String.downcase(software)), uncached}

          :miss ->
            {cached, [domain | uncached]}

          {:error, :unknown} ->
            # Already tried and failed, skip
            {cached, uncached}
        end
      end)

    {:reply, {cached_map, Enum.reverse(uncached)}, state}
  end

  @impl true
  def handle_cast({:cache_batch, results}, state) when is_map(results) do
    now = System.monotonic_time(:millisecond)

    new_cache =
      Enum.reduce(results, state.cache, fn {domain, software}, cache ->
        Map.put(cache, domain, {software, now})
      end)

    {:noreply, %{state | cache: new_cache}}
  end

  @impl true
  def handle_cast({:cache_failures, domains}, state) when is_list(domains) do
    now = System.monotonic_time(:millisecond)

    new_cache =
      Enum.reduce(domains, state.cache, fn domain, cache ->
        Map.put(cache, domain, {:unknown, now})
      end)

    {:noreply, %{state | cache: new_cache}}
  end

  defp check_cache(cache, domain) do
    case Map.get(cache, domain) do
      nil ->
        :miss

      {:unknown, _timestamp} ->
        {:error, :unknown}

      {software, timestamp} ->
        age = System.monotonic_time(:millisecond) - timestamp

        if age < @cache_ttl do
          {:ok, software}
        else
          :miss
        end
    end
  end

  defp fetch_nodeinfo(domain) do
    # First fetch the well-known nodeinfo to get the actual nodeinfo URL
    well_known_url = "https://#{domain}/.well-known/nodeinfo"

    with {:ok, %Finch.Response{status: 200, body: body}} <-
           Finch.build(:get, well_known_url, [{"Accept", "application/json"}])
           |> Finch.request(Elektrine.Finch, receive_timeout: 5000),
         {:ok, data} <- Jason.decode(body),
         nodeinfo_url when is_binary(nodeinfo_url) <- get_nodeinfo_url(data),
         {:ok, software} <- fetch_software_from_nodeinfo(nodeinfo_url) do
      {:ok, software}
    else
      error ->
        Logger.debug("Failed to fetch nodeinfo for #{domain}: #{inspect(error)}")
        {:error, :fetch_failed}
    end
  end

  defp get_nodeinfo_url(%{"links" => links}) when is_list(links) do
    # Prefer 2.1, then 2.0
    link =
      Enum.find(links, fn l ->
        l["rel"] in [
          "http://nodeinfo.diaspora.software/ns/schema/2.1",
          "http://nodeinfo.diaspora.software/ns/schema/2.0"
        ]
      end)

    case link do
      %{"href" => href} -> href
      _ -> nil
    end
  end

  defp get_nodeinfo_url(_), do: nil

  defp fetch_software_from_nodeinfo(url) do
    case Finch.build(:get, url, [{"Accept", "application/json"}])
         |> Finch.request(Elektrine.Finch, receive_timeout: 5000) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"software" => %{"name" => name}}} when is_binary(name) ->
            {:ok, String.downcase(name)}

          _ ->
            {:error, :invalid_nodeinfo}
        end

      _ ->
        {:error, :fetch_failed}
    end
  end
end
