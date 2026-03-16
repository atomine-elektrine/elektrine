defmodule Elektrine.Messaging.ReferencePeerSessionServer do
  @moduledoc false
  use GenServer
  import Bitwise

  alias Elektrine.Messaging.ReferencePeer
  alias Elektrine.Messaging.ReferencePeerProtocol

  @subprotocol "arblarg.session.v1"
  @websocket_magic "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  @hello_frame %{
    "op" => "hello",
    "protocol" => "arblarg",
    "transport" => "session_websocket",
    "session_version" => 1,
    "mode" => "stream_session",
    "encodings" => ["json", "cbor"],
    "flow_control" => %{
      "mode" => "ack_window",
      "max_inflight_batches" => 8,
      "max_inflight_events" => 256
    }
  }

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def port(server), do: GenServer.call(server, :port)
  def current_peer(server), do: GenServer.call(server, :current_peer)

  @impl true
  def init(opts) do
    peer = Keyword.fetch!(opts, :peer)
    remote_key_lookup_fun = Keyword.fetch!(opts, :remote_key_lookup_fun)
    notify = Keyword.get(opts, :notify)
    port = Keyword.get(opts, :port, 0)

    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, actual_port} = :inet.port(listener)
    server = self()
    acceptor = spawn_link(fn -> accept_loop(server, listener, remote_key_lookup_fun, notify) end)

    {:ok,
     %{
       listener: listener,
       acceptor: acceptor,
       port: actual_port,
       peer: peer,
       remote_key_lookup_fun: remote_key_lookup_fun,
       notify: notify
     }}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call(:current_peer, _from, state), do: {:reply, state.peer, state}

  def handle_call({:receive_stream_batch, delivery_id, payload}, _from, state) do
    notify(state.notify, {:server_call, :receive_stream_batch, delivery_id})

    result =
      case payload do
        %{
          "version" => 1,
          "delivery_id" => ^delivery_id,
          "stream_id" => stream_id,
          "events" => events
        }
        when is_binary(delivery_id) and is_binary(stream_id) and is_list(events) and events != [] ->
          case ReferencePeer.receive_event_batch(
                 state.peer,
                 %{"batch_id" => delivery_id, "events" => events},
                 state.remote_key_lookup_fun
               ) do
            {:ok, next_peer, batch_result} ->
              {:ok, %{state | peer: next_peer}, batch_result}

            {:error, reason} ->
              {:error, state, reason}
          end

        _ ->
          {:error, state, :invalid_payload}
      end

    case result do
      {:ok, next_state, ack_payload} ->
        notify(state.notify, {:server_reply, :receive_stream_batch, delivery_id, :ok})
        {:reply, {:ok, ack_payload}, next_state}

      {:error, next_state, reason} ->
        notify(
          state.notify,
          {:server_reply, :receive_stream_batch, delivery_id, {:error, reason}}
        )

        {:reply, {:error, reason}, next_state}
    end
  end

  def handle_call({:receive_ephemeral, delivery_id, payload}, _from, state) do
    result =
      case payload do
        %{"version" => 1, "delivery_id" => ^delivery_id, "items" => items}
        when is_binary(delivery_id) and is_list(items) and items != [] ->
          results =
            Enum.map(items, fn item ->
              %{"event_type" => item["event_type"], "status" => "applied"}
            end)

          {:ok,
           %{
             "version" => 1,
             "batch_id" => delivery_id,
             "event_count" => length(items),
             "results" => results,
             "counts" => %{"applied" => length(items)},
             "error_counts" => %{}
           }}

        _ ->
          {:error, :invalid_payload}
      end

    {:reply, result, state}
  end

  def handle_call({:stream_events, stream_id, after_sequence, limit}, _from, state) do
    {:reply,
     {:ok,
      ReferencePeer.export_stream_events(state.peer, stream_id,
        after_sequence: after_sequence,
        limit: limit
      )}, state}
  end

  def handle_call(_request, _from, state), do: {:reply, {:error, :unsupported_operation}, state}

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listener)
    :ok
  end

  defp accept_loop(server, listener, remote_key_lookup_fun, notify) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        session_pid =
          spawn_link(fn ->
            receive do
              :socket_ready -> session_loop(socket, server, remote_key_lookup_fun, notify)
            end
          end)

        case :gen_tcp.controlling_process(socket, session_pid) do
          :ok ->
            send(session_pid, :socket_ready)

          _ ->
            :gen_tcp.close(socket)
        end

        accept_loop(server, listener, remote_key_lookup_fun, notify)

      _ ->
        :ok
    end
  end

  defp session_loop(socket, server, remote_key_lookup_fun, notify) do
    with {:ok, request} <- recv_http_request(socket, <<>>),
         :ok <- verify_session_request(request, remote_key_lookup_fun),
         :ok <-
           send_handshake_response(socket, request.websocket_key, request.subprotocol_requested?),
         :ok <- send_frame(socket, {:text, Jason.encode!(@hello_frame)}) do
      notify(notify, {:handshake_complete, request.path})
      receive_frames(socket, server, notify, <<>>)
    else
      error ->
        notify(notify, {:session_failed, error})
        :gen_tcp.close(socket)
    end
  end

  defp receive_frames(socket, server, notify, buffer) do
    case recv_frame(socket, buffer) do
      {:ok, {:text, payload}, rest} ->
        with {:ok, decoded} <- Jason.decode(payload),
             :ok <- handle_frame(socket, server, notify, decoded, :json) do
          receive_frames(socket, server, notify, rest)
        else
          error ->
            notify(notify, {:receive_failed, error})
            :gen_tcp.close(socket)
        end

      {:ok, {:binary, payload}, rest} ->
        with {:ok, decoded, ""} <- CBOR.decode(payload),
             :ok <- handle_frame(socket, server, notify, decoded, :cbor) do
          receive_frames(socket, server, notify, rest)
        else
          error ->
            notify(notify, {:receive_failed, error})
            :gen_tcp.close(socket)
        end

      {:ok, {:ping, payload}, rest} ->
        _ = send_control(socket, :pong, payload)
        receive_frames(socket, server, notify, rest)

      {:ok, {:pong, _payload}, rest} ->
        receive_frames(socket, server, notify, rest)

      {:ok, {:close, _payload}, _rest} ->
        notify(notify, :peer_closed)
        :gen_tcp.close(socket)

      error ->
        notify(notify, {:receive_failed, error})
        :gen_tcp.close(socket)
    end
  end

  defp handle_frame(
         socket,
         server,
         notify,
         %{"op" => "stream_batch", "delivery_id" => delivery_id, "payload" => payload},
         encoding
       )
       when is_binary(delivery_id) do
    notify(notify, {:frame, "stream_batch", delivery_id})

    case GenServer.call(server, {:receive_stream_batch, delivery_id, payload || %{}}) do
      {:ok, ack_payload} ->
        notify(notify, {:ack_sent, delivery_id, :ok})

        send_frame(
          socket,
          encode_payload(
            %{
              "op" => "ack",
              "delivery_id" => delivery_id,
              "status" => "ok",
              "payload" => ack_payload
            },
            encoding
          )
        )

      {:error, reason} ->
        notify(notify, {:ack_sent, delivery_id, {:error, reason}})

        send_frame(
          socket,
          encode_payload(
            %{
              "op" => "ack",
              "delivery_id" => delivery_id,
              "status" => "error",
              "code" => to_string(reason)
            },
            encoding
          )
        )
    end
  end

  defp handle_frame(
         socket,
         server,
         notify,
         %{"op" => "deliver_ephemeral", "delivery_id" => delivery_id, "payload" => payload},
         encoding
       )
       when is_binary(delivery_id) do
    notify(notify, {:frame, "deliver_ephemeral", delivery_id})

    case GenServer.call(server, {:receive_ephemeral, delivery_id, payload || %{}}) do
      {:ok, ack_payload} ->
        notify(notify, {:ack_sent, delivery_id, :ok})

        send_frame(
          socket,
          encode_payload(
            %{
              "op" => "ack",
              "delivery_id" => delivery_id,
              "status" => "ok",
              "payload" => ack_payload
            },
            encoding
          )
        )

      {:error, reason} ->
        notify(notify, {:ack_sent, delivery_id, {:error, reason}})

        send_frame(
          socket,
          encode_payload(
            %{
              "op" => "ack",
              "delivery_id" => delivery_id,
              "status" => "error",
              "code" => to_string(reason)
            },
            encoding
          )
        )
    end
  end

  defp handle_frame(
         socket,
         server,
         notify,
         %{"op" => "stream_events", "request_id" => request_id, "payload" => payload},
         encoding
       )
       when is_binary(request_id) do
    notify(notify, {:frame, "stream_events", request_id})

    response =
      case payload do
        %{"stream_id" => stream_id} when is_binary(stream_id) ->
          after_sequence = payload["after_sequence"] || 0
          limit = payload["limit"] || 128

          case GenServer.call(server, {:stream_events, stream_id, after_sequence, limit}) do
            {:ok, replay_payload} ->
              %{
                "op" => "response",
                "request_id" => request_id,
                "status" => "ok",
                "payload" => replay_payload
              }

            {:error, reason} ->
              %{
                "op" => "response",
                "request_id" => request_id,
                "status" => "error",
                "code" => to_string(reason)
              }
          end

        _ ->
          %{
            "op" => "response",
            "request_id" => request_id,
            "status" => "error",
            "code" => "invalid_payload"
          }
      end

    send_frame(socket, encode_payload(response, encoding))
  end

  defp handle_frame(
         socket,
         _server,
         _notify,
         %{"op" => "ping", "request_id" => request_id},
         encoding
       )
       when is_binary(request_id) do
    send_frame(
      socket,
      encode_payload(
        %{
          "op" => "response",
          "request_id" => request_id,
          "status" => "ok",
          "payload" => %{"status" => "pong"}
        },
        encoding
      )
    )
  end

  defp handle_frame(socket, _server, _notify, %{"request_id" => request_id}, encoding)
       when is_binary(request_id) do
    send_frame(
      socket,
      encode_payload(
        %{
          "op" => "response",
          "request_id" => request_id,
          "status" => "error",
          "code" => "unsupported_operation"
        },
        encoding
      )
    )
  end

  defp handle_frame(_socket, _server, _notify, _frame, _encoding), do: :ok

  defp verify_session_request(request, remote_key_lookup_fun) do
    ReferencePeerProtocol.verify_signed_headers(
      request.headers,
      "GET",
      request.path,
      request.query_string,
      "",
      remote_key_lookup_fun
    )
    |> case do
      {:ok, _domain} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp recv_http_request(socket, buffer) do
    case :binary.match(buffer, "\r\n\r\n") do
      {index, 4} ->
        header_block = binary_part(buffer, 0, index)
        parse_http_request(header_block)

      :nomatch ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> recv_http_request(socket, buffer <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_http_request(header_block) do
    [request_line | header_lines] = String.split(header_block, "\r\n", trim: true)

    with ["GET", request_target, "HTTP/1.1"] <- String.split(request_line, " ", parts: 3),
         {path, query_string} <- split_request_target(request_target) do
      headers =
        Enum.map(header_lines, fn line ->
          case String.split(line, ":", parts: 2) do
            [key, value] -> {String.downcase(String.trim(key)), String.trim(value)}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      websocket_key =
        headers
        |> Enum.find_value(fn
          {"sec-websocket-key", value} -> value
          _ -> nil
        end)

      subprotocol_requested? = requested_subprotocol?(headers)

      if is_binary(websocket_key) and path == "/_arblarg/session" do
        {:ok,
         %{
           path: path,
           query_string: query_string,
           headers: headers,
           websocket_key: websocket_key,
           subprotocol_requested?: subprotocol_requested?
         }}
      else
        {:error, :invalid_session_handshake}
      end
    else
      _ -> {:error, :invalid_session_handshake}
    end
  end

  defp split_request_target(request_target) when is_binary(request_target) do
    case String.split(request_target, "?", parts: 2) do
      [path, query] -> {path, query}
      [path] -> {path, ""}
    end
  end

  defp send_handshake_response(socket, websocket_key, subprotocol_requested?) do
    accept =
      websocket_key
      |> Kernel.<>(@websocket_magic)
      |> then(&:crypto.hash(:sha, &1))
      |> Base.encode64()

    response = [
      "HTTP/1.1 101 Switching Protocols\r\n",
      "connection: Upgrade\r\n",
      "upgrade: websocket\r\n",
      "sec-websocket-accept: ",
      accept,
      "\r\n"
    ]

    response =
      if subprotocol_requested? do
        response ++ ["sec-websocket-protocol: ", @subprotocol, "\r\n"]
      else
        response
      end

    response = response ++ ["\r\n"]

    :gen_tcp.send(socket, response)
  end

  defp requested_subprotocol?(headers) when is_list(headers) do
    headers
    |> Enum.find_value(fn
      {"sec-websocket-protocol", value} -> value
      _ -> nil
    end)
    |> case do
      value when is_binary(value) ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.member?(@subprotocol)

      _ ->
        false
    end
  end

  defp requested_subprotocol?(_headers), do: false

  defp encode_payload(payload, :cbor), do: {:binary, CBOR.encode(payload)}
  defp encode_payload(payload, _encoding), do: {:text, Jason.encode!(payload)}

  defp send_frame(socket, {:text, payload}) when is_binary(payload) do
    :gen_tcp.send(socket, [<<0x81>>, length_prefix(byte_size(payload), false), payload])
  end

  defp send_frame(socket, {:binary, payload}) when is_binary(payload) do
    :gen_tcp.send(socket, [<<0x82>>, length_prefix(byte_size(payload), false), payload])
  end

  defp send_control(socket, opcode, payload)
       when opcode in [:pong, :ping] and is_binary(payload) do
    opcode_byte = if(opcode == :ping, do: 0x9, else: 0xA)

    :gen_tcp.send(socket, [
      <<0x80 ||| opcode_byte>>,
      length_prefix(byte_size(payload), false),
      payload
    ])
  end

  defp recv_frame(socket, buffer) do
    case decode_client_frame(buffer) do
      {:ok, frame, rest} ->
        {:ok, frame, rest}

      :more ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> recv_frame(socket, buffer <> data)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_client_frame(<<>>), do: :more

  defp decode_client_frame(<<first, second, rest::binary>>) do
    fin? = (first &&& 0x80) == 0x80
    opcode = first &&& 0x0F
    masked? = (second &&& 0x80) == 0x80
    payload_length = second &&& 0x7F

    with true <- fin?,
         true <- masked?,
         {:ok, payload_length, rest} <- parse_payload_length(payload_length, rest),
         {:ok, mask, rest} <- parse_mask(rest),
         {:ok, payload, rest} <- parse_payload(rest, payload_length) do
      payload = mask_payload(payload, mask)

      case opcode do
        0x1 -> {:ok, {:text, payload}, rest}
        0x2 -> {:ok, {:binary, payload}, rest}
        0x8 -> {:ok, {:close, payload}, rest}
        0x9 -> {:ok, {:ping, payload}, rest}
        0xA -> {:ok, {:pong, payload}, rest}
        _ -> {:error, :invalid_session_frame}
      end
    else
      :more -> :more
      false -> {:error, :invalid_session_frame}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_payload_length(126, <<length::16, rest::binary>>), do: {:ok, length, rest}
  defp parse_payload_length(126, _buffer), do: :more
  defp parse_payload_length(127, <<length::64, rest::binary>>), do: {:ok, length, rest}
  defp parse_payload_length(127, _buffer), do: :more
  defp parse_payload_length(length, rest) when is_integer(length), do: {:ok, length, rest}

  defp parse_mask(<<mask::binary-size(4), rest::binary>>), do: {:ok, mask, rest}
  defp parse_mask(_buffer), do: :more

  defp parse_payload(buffer, payload_length) when byte_size(buffer) < payload_length, do: :more

  defp parse_payload(buffer, payload_length) do
    payload = binary_part(buffer, 0, payload_length)
    rest = binary_part(buffer, payload_length, byte_size(buffer) - payload_length)
    {:ok, payload, rest}
  end

  defp length_prefix(length, masked?) when length < 126 do
    mask_bit = if(masked?, do: 0x80, else: 0x00)
    <<mask_bit ||| length>>
  end

  defp length_prefix(length, masked?) when length <= 0xFFFF do
    mask_bit = if(masked?, do: 0x80, else: 0x00)
    <<mask_bit ||| 126, length::16>>
  end

  defp length_prefix(length, masked?) do
    mask_bit = if(masked?, do: 0x80, else: 0x00)
    <<mask_bit ||| 127, length::64>>
  end

  defp mask_payload(payload, mask) when is_binary(payload) and is_binary(mask) do
    mask_bytes = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} ->
      Bitwise.bxor(byte, Enum.at(mask_bytes, rem(index, 4)))
    end)
    |> :erlang.list_to_binary()
  end

  defp notify(nil, _message), do: :ok
  defp notify(pid, message) when is_pid(pid), do: send(pid, {:reference_peer_session, message})
  defp notify(_notify, _message), do: :ok
end
