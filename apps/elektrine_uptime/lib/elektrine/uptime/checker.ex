defmodule Elektrine.Uptime.Checker do
  @moduledoc """
  Default implementation of `Elektrine.Uptime.Checker.Behaviour`.

  Probes a monitor target and reports `{:up, %{response_time_ms, status_code}}`
  or `{:down, reason_string}`.

  ## Security (SSRF)

  Every target is validated through `Elektrine.Security.URLValidator` and
  connections are pinned to the resolved **public** IP address. Without this an
  uptime monitor that accepts an arbitrary host:port is an internal port-scanner.

    * HTTP goes through `Elektrine.HTTP.SafeFetch` (validates + pins the IP).
    * TCP resolves the host to a public IP tuple, rejects dangerous ports, and
      connects to the pinned tuple.
    * PING validates the host is public before shelling out to `ping` with the
      args passed as a list (never a shell string).

  ## ICMP / ping privileges

  `ping` typically requires the binary to be setuid root or to hold the
  `CAP_NET_RAW` capability. When the binary is missing or refuses to run, the
  check degrades to `{:down, "ping unavailable"}` - TCP is the privilege-free
  alternative for reachability checks.

  ## Test injection

  Each transport resolves its worker function from application env so tests can
  stub them without real sockets:

    * `:http_fun`        - `fun.(request, finch_name, opts)`
    * `:tcp_connect_fun` - `fun.(ip, port, opts, timeout_ms)`
    * `:ping_fun`        - `fun.(host, timeout_seconds)`

  The real SSRF guard (`URLValidator`) still runs even with stubbed transports.
  """

  @behaviour Elektrine.Uptime.Checker.Behaviour

  require Logger

  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.Security.URLValidator
  alias Elektrine.Uptime.Monitor

  @user_agent "Elektrine-Uptime/1.0"

  @impl true
  def run(%Monitor{check_type: "http"} = monitor), do: run_http(monitor)
  def run(%Monitor{check_type: "tcp"} = monitor), do: run_tcp(monitor)
  def run(%Monitor{check_type: "ping"} = monitor), do: run_ping(monitor)
  def run(%Monitor{check_type: other}), do: {:down, "unsupported check type: #{inspect(other)}"}

  ## HTTP

  defp run_http(%Monitor{target: target, timeout_ms: timeout_ms} = monitor) do
    case URLValidator.validate(target) do
      :ok ->
        request = Finch.build(:get, target, [{"user-agent", @user_agent}])
        http_fun = http_fun()

        {elapsed_us, result} =
          :timer.tc(fn ->
            http_fun.(request, Elektrine.Finch, receive_timeout: timeout_ms)
          end)

        response_time_ms = div(elapsed_us, 1000)
        interpret_http(result, monitor, response_time_ms)

      {:error, reason} ->
        {:down, "blocked: #{reason}"}
    end
  end

  defp interpret_http(
         {:ok, %Finch.Response{status: status, body: body}},
         monitor,
         response_time_ms
       ) do
    cond do
      not status_ok?(status, monitor.expected_status) ->
        {:down, "unexpected status #{status}"}

      keyword_missing?(monitor.keyword, body) ->
        {:down, "keyword not found"}

      true ->
        {:up, %{response_time_ms: response_time_ms, status_code: status}}
    end
  end

  defp interpret_http({:error, reason}, _monitor, _response_time_ms) do
    {:down, "http: #{describe(reason)}"}
  end

  defp status_ok?(status, nil), do: status in 200..299
  defp status_ok?(status, expected), do: status == expected

  defp keyword_missing?(nil, _body), do: false
  defp keyword_missing?("", _body), do: false

  defp keyword_missing?(keyword, body) when is_binary(body),
    do: not String.contains?(body, keyword)

  defp keyword_missing?(_keyword, _body), do: true

  ## TCP

  defp run_tcp(%Monitor{target: host, port: port, timeout_ms: timeout_ms}) do
    with {:ok, ip} <- URLValidator.resolve_public_address(host),
         :ok <- check_tcp_port(host, port) do
      connect_fun = tcp_connect_fun()

      {elapsed_us, result} =
        :timer.tc(fn ->
          connect_fun.(ip, port, [:binary, active: false], timeout_ms)
        end)

      response_time_ms = div(elapsed_us, 1000)

      case result do
        {:ok, socket} ->
          _ = safe_close(socket)
          {:up, %{response_time_ms: response_time_ms, status_code: nil}}

        {:error, reason} ->
          {:down, "tcp: #{describe(reason)}"}
      end
    else
      {:error, reason} -> {:down, "tcp: #{describe(reason)}"}
    end
  end

  defp safe_close(socket) do
    :gen_tcp.close(socket)
  rescue
    _ -> :ok
  end

  defp check_tcp_port(host, port) do
    uri = %URI{host: host, port: port}

    if URLValidator.dangerous_port?(uri) do
      {:error, :dangerous_port}
    else
      :ok
    end
  end

  ## PING

  defp run_ping(%Monitor{target: host, timeout_ms: timeout_ms}) do
    case URLValidator.resolve_public_address(host) do
      {:ok, _ip} ->
        timeout_seconds = max(1, div(timeout_ms, 1000))
        ping_fun = ping_fun()

        {elapsed_us, result} = :timer.tc(fn -> ping_fun.(host, timeout_seconds) end)
        fallback_ms = div(elapsed_us, 1000)
        interpret_ping(result, fallback_ms)

      {:error, reason} ->
        {:down, "ping: #{describe(reason)}"}
    end
  rescue
    e in [ErlangError] ->
      Logger.debug("ping unavailable: #{inspect(e)}")
      {:down, "ping unavailable"}
  end

  defp interpret_ping({output, 0}, fallback_ms) when is_binary(output) do
    {:up, %{response_time_ms: parse_ping_rtt(output) || fallback_ms, status_code: nil}}
  end

  defp interpret_ping({output, code}, _fallback_ms) when is_binary(output) and is_integer(code) do
    {:down, "ping failed (exit #{code})"}
  end

  defp interpret_ping(_other, _fallback_ms), do: {:down, "ping unavailable"}

  defp parse_ping_rtt(output) do
    case Regex.run(~r/time[=<]\s*([\d.]+)\s*ms/i, output) do
      [_, value] ->
        case Float.parse(value) do
          {ms, _} -> round(ms)
          :error -> nil
        end

      _ ->
        nil
    end
  end

  ## Transport resolution + defaults

  defp http_fun do
    Application.get_env(:elektrine_uptime, :http_fun, &default_http_fun/3)
  end

  defp default_http_fun(request, finch_name, opts) do
    SafeFetch.request(request, finch_name, opts)
  end

  defp tcp_connect_fun do
    Application.get_env(:elektrine_uptime, :tcp_connect_fun, &default_tcp_connect_fun/4)
  end

  defp default_tcp_connect_fun(ip, port, opts, timeout_ms) do
    :gen_tcp.connect(ip, port, opts, timeout_ms)
  end

  defp ping_fun do
    Application.get_env(:elektrine_uptime, :ping_fun, &default_ping_fun/2)
  end

  defp default_ping_fun(host, timeout_seconds) do
    case System.find_executable("ping") do
      nil ->
        {"ping executable not found", 127}

      ping ->
        System.cmd(ping, ["-c", "1", "-W", to_string(timeout_seconds), "--", host],
          stderr_to_stdout: true
        )
    end
  end

  ## Helpers

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)
end
