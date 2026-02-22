defmodule Elektrine.HTTP.Backoff do
  @moduledoc "HTTP client-side backoff handling for respecting remote server rate limits.\n\nThis module tracks rate-limited hosts and prevents hammering servers that\nhave returned 429 (Too Many Requests) or 503 (Service Unavailable) responses.\n\nBased on Akkoma's implementation for federation compatibility.\n\n## Usage\n\n    # Wrap HTTP requests\n    case Elektrine.HTTP.Backoff.get(url) do\n      {:ok, response} -> handle_response(response)\n      {:error, :backoff} -> # Host is rate-limited, try later\n      {:error, reason} -> # Other error\n    end\n\n    # Or check before making request\n    if Elektrine.HTTP.Backoff.should_backoff?(host) do\n      {:error, :rate_limited}\n    else\n      make_request(url)\n    end\n"
  use GenServer
  require Logger
  @table :http_backoff_cache
  @default_backoff_seconds 300
  @max_backoff_seconds 3600
  @cleanup_interval :timer.minutes(5)
  @doc "Starts the backoff tracker.\n"
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Makes an HTTP GET request with backoff handling.\nReturns {:error, :backoff} if the host is currently rate-limited.\n"
  def get(url, headers \\ [], opts \\ []) do
    uri = URI.parse(url)
    host = uri.host

    if should_backoff?(host) do
      Logger.debug("HTTP Backoff: Skipping request to #{host} - currently rate-limited")
      {:error, :backoff}
    else
      result = do_request(:get, url, "", headers, opts)
      handle_response(host, result)
    end
  end

  @doc "Makes an HTTP POST request with backoff handling.\n"
  def post(url, body, headers \\ [], opts \\ []) do
    uri = URI.parse(url)
    host = uri.host

    if should_backoff?(host) do
      Logger.debug("HTTP Backoff: Skipping request to #{host} - currently rate-limited")
      {:error, :backoff}
    else
      result = do_request(:post, url, body, headers, opts)
      handle_response(host, result)
    end
  end

  @doc "Checks if we should back off from making requests to the given host.\n"
  def should_backoff?(nil) do
    false
  end

  def should_backoff?(host) when is_binary(host) do
    case :ets.lookup(@table, host) do
      [{^host, backoff_until}] ->
        now = System.system_time(:second)
        now < backoff_until

      [] ->
        false
    end
  end

  @doc "Marks a host as rate-limited for the specified duration.\n"
  def set_backoff(host, seconds \\ @default_backoff_seconds) when is_binary(host) do
    seconds = min(seconds, @max_backoff_seconds)
    backoff_until = System.system_time(:second) + seconds
    :ets.insert(@table, {host, backoff_until})
    Logger.info("HTTP Backoff: Rate-limiting #{host} for #{seconds} seconds")
    :ok
  end

  @doc "Clears backoff for a host (e.g., after successful request).\n"
  def clear_backoff(host) when is_binary(host) do
    :ets.delete(@table, host)
    :ok
  end

  @doc "Gets the remaining backoff time for a host in seconds.\nReturns 0 if not rate-limited.\n"
  def get_backoff_remaining(host) when is_binary(host) do
    case :ets.lookup(@table, host) do
      [{^host, backoff_until}] ->
        remaining = backoff_until - System.system_time(:second)
        max(0, remaining)

      [] ->
        0
    end
  end

  @doc "Lists all currently rate-limited hosts.\n"
  def list_rate_limited do
    now = System.system_time(:second)

    :ets.tab2list(@table)
    |> Enum.filter(fn {_host, backoff_until} -> backoff_until > now end)
    |> Enum.map(fn {host, backoff_until} ->
      %{host: host, backoff_until: backoff_until, remaining: backoff_until - now}
    end)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    schedule_cleanup()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  defp do_request(method, url, body, headers, opts) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    recv_timeout = Keyword.get(opts, :recv_timeout, 15_000)
    request = Finch.build(method, url, headers, body)

    case Finch.request(request, Elektrine.Finch,
           receive_timeout: recv_timeout,
           pool_timeout: timeout
         ) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_response(host, {:ok, %Finch.Response{status: status, headers: headers} = response})
       when status in [429, 503] do
    backoff_seconds = parse_retry_after(headers)
    set_backoff(host, backoff_seconds)
    {:ok, response}
  end

  defp handle_response(host, {:ok, %Finch.Response{status: status} = response})
       when status >= 200 and status < 300 do
    clear_backoff(host)
    {:ok, response}
  end

  defp handle_response(_host, {:ok, response}) do
    {:ok, response}
  end

  defp handle_response(_host, {:error, reason}) do
    {:error, reason}
  end

  @doc "Parses the Retry-After header to determine backoff duration.\nSupports both seconds format and HTTP-date format.\nAlso checks X-RateLimit-Reset header.\n"
  def parse_retry_after(headers) do
    headers_map = headers_to_map(headers)

    cond do
      retry_after = Map.get(headers_map, "retry-after") ->
        parse_retry_after_value(retry_after)

      rate_limit_reset = Map.get(headers_map, "x-ratelimit-reset") ->
        parse_rate_limit_reset(rate_limit_reset)

      true ->
        @default_backoff_seconds
    end
  end

  defp headers_to_map(headers) do
    headers |> Enum.map(fn {k, v} -> {String.downcase(k), v} end) |> Map.new()
  end

  defp parse_retry_after_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> min(seconds, @max_backoff_seconds)
      _ -> parse_http_date(value)
    end
  end

  defp parse_retry_after_value(_) do
    @default_backoff_seconds
  end

  defp parse_rate_limit_reset(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} ->
        now = System.system_time(:second)
        seconds = max(0, timestamp - now)
        min(seconds, @max_backoff_seconds)

      _ ->
        @default_backoff_seconds
    end
  end

  defp parse_rate_limit_reset(_) do
    @default_backoff_seconds
  end

  defp parse_http_date(date_string) do
    case :httpd_util.convert_request_date(String.to_charlist(date_string)) do
      {{year, month, day}, {hour, minute, second}} ->
        {:ok, datetime} = NaiveDateTime.new(year, month, day, hour, minute, second)
        {:ok, utc_datetime} = DateTime.from_naive(datetime, "Etc/UTC")
        now = DateTime.utc_now()
        diff = DateTime.diff(utc_datetime, now, :second)
        min(max(0, diff), @max_backoff_seconds)

      :bad_date ->
        @default_backoff_seconds
    end
  rescue
    _ -> @default_backoff_seconds
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp cleanup_expired do
    now = System.system_time(:second)

    :ets.tab2list(@table)
    |> Enum.filter(fn {_host, backoff_until} -> backoff_until <= now end)
    |> Enum.each(fn {host, _} -> :ets.delete(@table, host) end)
  end
end
