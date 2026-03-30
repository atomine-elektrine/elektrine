defmodule Elektrine.HTTP.SafeFetch do
  @moduledoc """
  Fetches remote HTTP responses through a pinned, prevalidated IP address.
  """

  alias Elektrine.Security.URLValidator
  alias Finch.Request

  @default_max_body_bytes 2 * 1024 * 1024

  def request(request, finch_name, opts \\ [])

  def request(%Request{} = request, _finch_name, opts) do
    max_body_bytes = Keyword.get(opts, :max_body_bytes, @default_max_body_bytes)

    with {:ok, address} <- resolve_request_address(request, opts),
         {:ok, conn} <- connect(request, address, opts),
         {:ok, conn, ref} <-
           Mint.HTTP.request(
             conn,
             request.method,
             Request.request_path(request),
             request_headers(request),
             request_body(request)
           ) do
      receive_response(conn, ref, max_body_bytes, request_receive_timeout(opts))
    end
  end

  def request(_request, _finch_name, _opts), do: {:error, :invalid_request}

  defp resolve_request_address(%Request{host: host, scheme: :http}, opts) do
    if Keyword.get(opts, :allow_localhost, false) and host in ["localhost", "127.0.0.1", "::1"] do
      case host do
        "localhost" ->
          {:ok, {127, 0, 0, 1}}

        _ ->
          case :inet.parse_address(String.to_charlist(host)) do
            {:ok, address} -> {:ok, address}
            {:error, _} -> {:error, :unresolvable_host}
          end
      end
    else
      URLValidator.resolve_public_address(host)
    end
  end

  defp resolve_request_address(%Request{host: host}, _opts),
    do: URLValidator.resolve_public_address(host)

  defp connect(request, address, opts) do
    Mint.HTTP.connect(
      request.scheme,
      address,
      request_port(request),
      hostname: request.host,
      protocols: [:http1],
      transport_opts: [timeout: request_connect_timeout(opts)]
    )
  end

  defp receive_response(conn, ref, max_body_bytes, receive_timeout) do
    receive_loop(
      conn,
      ref,
      %{status: nil, headers: [], body: [], body_size: 0},
      max_body_bytes,
      receive_timeout
    )
  end

  defp receive_loop(conn, ref, acc, max_body_bytes, receive_timeout) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, responses} ->
            case handle_responses(conn, ref, responses, acc, max_body_bytes) do
              {:continue, conn, acc} ->
                receive_loop(conn, ref, acc, max_body_bytes, receive_timeout)

              result ->
                result
            end

          {:error, conn, reason, responses} ->
            case handle_responses(conn, ref, responses, acc, max_body_bytes) do
              {:continue, conn, _acc} -> close_with_error(conn, reason)
              result -> result
            end
        end
    after
      receive_timeout ->
        close_with_error(conn, :timeout)
    end
  end

  defp handle_responses(conn, ref, responses, acc, max_body_bytes) do
    Enum.reduce_while(responses, {:continue, conn, acc}, fn
      {:status, ^ref, status}, {:continue, conn, acc} ->
        {:cont, {:continue, conn, %{acc | status: status}}}

      {:headers, ^ref, headers}, {:continue, conn, acc} ->
        if content_length_too_large?(headers, max_body_bytes) do
          {:halt, close_with_error(conn, :too_large)}
        else
          {:cont, {:continue, conn, %{acc | headers: headers}}}
        end

      {:data, ^ref, data}, {:continue, conn, acc} ->
        new_size = acc.body_size + byte_size(data)

        if is_integer(max_body_bytes) and new_size > max_body_bytes do
          {:halt, close_with_error(conn, :too_large)}
        else
          {:cont, {:continue, conn, %{acc | body: [data | acc.body], body_size: new_size}}}
        end

      {:done, ^ref}, {:continue, conn, acc} ->
        {:halt, close_with_response(conn, acc)}

      {:error, ^ref, reason}, {:continue, conn, _acc} ->
        {:halt, close_with_error(conn, reason)}

      _, state ->
        {:cont, state}
    end)
  end

  defp close_with_response(conn, %{status: status, headers: headers, body: body})
       when is_integer(status) do
    _ = Mint.HTTP.close(conn)

    {:ok,
     %Finch.Response{
       status: status,
       headers: headers,
       body: body |> Enum.reverse() |> IO.iodata_to_binary()
     }}
  end

  defp close_with_response(conn, _acc) do
    _ = Mint.HTTP.close(conn)
    {:error, :invalid_response}
  end

  defp close_with_error(conn, reason) do
    _ = Mint.HTTP.close(conn)
    {:error, reason}
  end

  defp request_headers(%Request{} = request) do
    if Enum.any?(request.headers, fn {name, _value} -> String.downcase(name) == "host" end) do
      request.headers
    else
      [{"host", host_header(request)} | request.headers]
    end
  end

  defp host_header(%Request{host: host, port: port, scheme: scheme}) do
    cond do
      scheme == :http and port in [nil, 80] -> host
      scheme == :https and port in [nil, 443] -> host
      true -> "#{host}:#{request_port(port, scheme)}"
    end
  end

  defp request_body(%Request{body: nil}), do: ""

  defp request_body(%Request{body: {:stream, _enumerable}}) do
    raise ArgumentError, "streaming request bodies are not supported by SafeFetch"
  end

  defp request_body(%Request{body: body}), do: body

  defp request_port(%Request{port: port, scheme: scheme}), do: request_port(port, scheme)

  defp request_port(nil, :http), do: 80
  defp request_port(nil, :https), do: 443
  defp request_port(port, _scheme), do: port

  defp request_connect_timeout(opts), do: Keyword.get(opts, :pool_timeout, 15_000)
  defp request_receive_timeout(opts), do: Keyword.get(opts, :receive_timeout, 15_000)

  defp content_length_too_large?(_headers, nil), do: false

  defp content_length_too_large?(headers, max_body_bytes) do
    headers
    |> Enum.find_value(fn {name, value} ->
      if String.downcase(name) == "content-length", do: parse_integer(value)
    end)
    |> case do
      length when is_integer(length) -> length > max_body_bytes
      _ -> false
    end
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil
end
