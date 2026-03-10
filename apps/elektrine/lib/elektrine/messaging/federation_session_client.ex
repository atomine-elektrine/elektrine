defmodule Elektrine.Messaging.FederationSessionClient do
  @moduledoc false
  use GenServer
  import Bitwise

  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Federation.Config

  @default_timeout 12_000
  @connect_timeout 5_000
  @default_max_inflight_batches 4
  @default_max_inflight_events 128
  @websocket_magic "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  @subprotocol "arblarg.session.v1"

  defstruct [
    :domain,
    :peer,
    :socket,
    :transport,
    :request_path,
    :query_string,
    :encoding,
    buffer: <<>>,
    pending_requests: %{},
    pending_deliveries: %{},
    queued_deliveries: :queue.new(),
    inflight_batches: 0,
    inflight_events: 0,
    inflight_streams: MapSet.new(),
    max_inflight_batches: @default_max_inflight_batches,
    max_inflight_events: @default_max_inflight_events,
    hello_received?: false
  ]

  def start_link(%{} = peer) do
    GenServer.start_link(__MODULE__, peer, name: via(peer.domain))
  end

  def send_request(peer, operation, payload, opts \\ [])
      when is_map(peer) and is_binary(operation) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, pid} <- ensure_started(peer) do
      try do
        GenServer.call(pid, {:request, peer, operation, payload, opts}, timeout + 1_000)
      catch
        :exit, {:timeout, _} -> {:error, :session_timeout}
      end
    end
  end

  def send_delivery(peer, operation, payload, opts \\ [])
      when is_map(peer) and is_binary(operation) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, pid} <- ensure_started(peer) do
      try do
        GenServer.call(pid, {:delivery, peer, operation, payload, opts}, timeout + 1_000)
      catch
        :exit, {:timeout, _} -> {:error, :session_timeout}
      end
    end
  end

  @impl true
  def init(%{} = peer) do
    {:ok,
     %__MODULE__{
       domain: String.downcase(to_string(peer.domain)),
       peer: peer,
       encoding: preferred_encoding(peer)
     }}
  end

  @impl true
  def handle_call({:request, peer, operation, payload, opts}, from, state) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    state = %{state | peer: peer, encoding: preferred_encoding(peer)}

    with {:ok, state} <- ensure_connected(state),
         request_id <- Ecto.UUID.generate(),
         :ok <- send_request_frame(state, operation, request_id, payload) do
      notify(state, {:request_sent, operation, request_id})
      state = put_pending_request(state, request_id, from, timeout)
      {:noreply, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, fail_and_disconnect(state, reason)}
    end
  end

  def handle_call({:delivery, peer, operation, payload, opts}, from, state) do
    state = %{state | peer: peer, encoding: preferred_encoding(peer)}

    with {:ok, state} <- ensure_connected(state),
         {:ok, state} <- enqueue_or_send_delivery(state, from, operation, payload, opts) do
      {:noreply, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, fail_and_disconnect(state, reason)}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, %__MODULE__{socket: socket} = state) do
    state
    |> append_socket_data(data)
    |> continue_after_socket_data(:gen_tcp)
  end

  def handle_info({:ssl, socket, data}, %__MODULE__{socket: socket} = state) do
    state
    |> append_socket_data(data)
    |> continue_after_socket_data(:ssl)
  end

  def handle_info({:tcp_closed, socket}, %__MODULE__{socket: socket} = state) do
    {:noreply, fail_and_disconnect(state, :session_closed)}
  end

  def handle_info({:ssl_closed, socket}, %__MODULE__{socket: socket} = state) do
    {:noreply, fail_and_disconnect(state, :session_closed)}
  end

  def handle_info({:tcp_error, socket, reason}, %__MODULE__{socket: socket} = state) do
    {:noreply, fail_and_disconnect(state, {:session_transport_failed, reason})}
  end

  def handle_info({:ssl_error, socket, reason}, %__MODULE__{socket: socket} = state) do
    {:noreply, fail_and_disconnect(state, {:session_transport_failed, reason})}
  end

  def handle_info({:session_timeout, :request, request_id}, state) do
    {:noreply, fail_pending_request(state, request_id, :session_timeout)}
  end

  def handle_info({:session_timeout, :delivery, delivery_id}, state) do
    {:noreply, fail_pending_delivery(state, delivery_id, :session_timeout)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = close_socket(state)
    :ok
  end

  defp ensure_started(%{} = peer) do
    domain = String.downcase(to_string(peer.domain))

    case Registry.lookup(Elektrine.Messaging.FederationSessionRegistry, domain) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Elektrine.Messaging.FederationSessionSupervisor,
               {__MODULE__, peer}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp via(domain) when is_binary(domain) do
    {:via, Registry, {Elektrine.Messaging.FederationSessionRegistry, String.downcase(domain)}}
  end

  defp ensure_connected(%__MODULE__{socket: socket} = state) when not is_nil(socket),
    do: {:ok, state}

  defp ensure_connected(%__MODULE__{peer: peer} = state) do
    with url when is_binary(url) <- Config.outbound_session_websocket_url(peer),
         {:ok, uri} <- parse_uri(url),
         {:ok, transport, socket} <- open_socket(uri),
         {:ok, response, request_path, query_string} <-
           websocket_handshake(peer, transport, socket, uri) do
      case validate_handshake_response(response) do
        {:ok, buffer} ->
          state = %{
            state
            | socket: socket,
              transport: transport,
              request_path: request_path,
              query_string: query_string,
              buffer: buffer
          }

          with :ok <- activate_socket(state),
               {:ok, state} <- process_buffer(state) do
            {:ok, state}
          else
            {:error, reason} ->
              _ = close_socket(state)
              {:error, reason}
          end

        {:error, reason} ->
          _ = close_socket(%{state | socket: socket, transport: transport})
          {:error, reason}
      end
    else
      nil -> {:error, :session_transport_unavailable}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :session_transport_unavailable}
    end
  end

  defp enqueue_or_send_delivery(state, from, operation, payload, opts) do
    event_count = delivery_event_count(operation, payload)
    stream_key = delivery_stream_key(operation, payload)

    if can_send_delivery?(state, event_count, stream_key) do
      send_delivery_now(state, from, operation, payload, opts, event_count, stream_key)
    else
      queued =
        :queue.in(
          %{
            from: from,
            operation: operation,
            payload: payload,
            opts: opts,
            event_count: event_count,
            stream_key: stream_key
          },
          state.queued_deliveries
        )

      {:ok, %{state | queued_deliveries: queued}}
    end
  end

  defp send_delivery_now(state, from, operation, payload, opts, event_count, stream_key) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    delivery_id = Ecto.UUID.generate()

    with :ok <- send_delivery_frame(state, operation, delivery_id, payload) do
      notify(state, {:delivery_sent, operation, delivery_id})
      timer_ref = Process.send_after(self(), {:session_timeout, :delivery, delivery_id}, timeout)

      state =
        state
        |> put_pending_delivery(delivery_id, from, timer_ref, event_count, stream_key)
        |> increment_inflight(event_count, stream_key)

      {:ok, state}
    end
  end

  defp continue_after_socket_data({:ok, state}, transport) do
    with :ok <- activate_socket(%{state | transport: transport}),
         {:ok, state} <- process_buffer(state),
         {:ok, state} <- drain_delivery_queue(state) do
      {:noreply, state}
    else
      {:error, reason} ->
        {:noreply, fail_and_disconnect(state, reason)}
    end
  end

  defp append_socket_data(%__MODULE__{} = state, data) when is_binary(data) do
    {:ok, %{state | buffer: state.buffer <> data}}
  end

  defp process_buffer(%__MODULE__{} = state) do
    case decode_server_frame(state.buffer) do
      {:ok, frame, rest} ->
        state = %{state | buffer: rest}

        with {:ok, state} <- route_frame(state, frame) do
          process_buffer(state)
        end

      :more ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_frame(state, {:ping, payload}) do
    case socket_send(state.transport, state.socket, encode_client_control(:pong, payload)) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, {:session_receive_failed, reason}}
    end
  end

  defp route_frame(state, {:pong, _payload}), do: {:ok, state}
  defp route_frame(_state, {:close, _payload}), do: {:error, :session_closed}

  defp route_frame(state, {:text, payload}) do
    with {:ok, frame} <- decode_text_payload(payload) do
      route_payload(state, frame)
    end
  end

  defp route_frame(state, {:binary, payload}) do
    with {:ok, frame} <- decode_binary_payload(payload) do
      route_payload(state, frame)
    end
  end

  defp route_payload(state, %{"op" => "hello"} = payload) do
    notify(state, {:hello_received, payload["mode"] || "unknown"})
    {:ok, apply_hello_frame(state, payload)}
  end

  defp route_payload(state, %{
         "op" => "response",
         "request_id" => request_id,
         "status" => "ok",
         "payload" => response
       })
       when is_binary(request_id) do
    notify(state, {:response_received, request_id, :ok})
    {:ok, fulfill_pending_request(state, request_id, {:ok, response})}
  end

  defp route_payload(state, %{
         "op" => "response",
         "request_id" => request_id,
         "status" => "error",
         "code" => code
       })
       when is_binary(request_id) do
    notify(state, {:response_received, request_id, {:error, code}})
    {:ok, fulfill_pending_request(state, request_id, {:error, response_reason(code)})}
  end

  defp route_payload(
         state,
         %{"op" => "ack", "delivery_id" => delivery_id, "status" => "ok", "payload" => payload}
       )
       when is_binary(delivery_id) do
    notify(state, {:ack_received, delivery_id, :ok})

    state =
      state
      |> fulfill_pending_delivery(delivery_id, {:ok, payload})
      |> maybe_drain_after_ack()

    {:ok, state}
  end

  defp route_payload(
         state,
         %{"op" => "ack", "delivery_id" => delivery_id, "status" => "error", "code" => code}
       )
       when is_binary(delivery_id) do
    notify(state, {:ack_received, delivery_id, {:error, code}})

    state =
      state
      |> fulfill_pending_delivery(delivery_id, {:error, response_reason(code)})
      |> maybe_drain_after_ack()

    {:ok, state}
  end

  defp route_payload(state, _payload), do: {:ok, state}

  defp apply_hello_frame(state, payload) do
    transport_profile =
      payload
      |> Map.get("transport_profiles", %{})
      |> Map.get("session_websocket", %{})

    flow_control =
      payload["flow_control"] ||
        transport_profile["flow_control"] ||
        %{}

    advertised_encodings =
      payload
      |> Map.get("encodings", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    %{
      state
      | max_inflight_batches:
          parse_positive_integer(
            flow_control["max_inflight_batches"],
            @default_max_inflight_batches
          ),
        max_inflight_events:
          parse_positive_integer(
            flow_control["max_inflight_events"],
            @default_max_inflight_events
          ),
        encoding: negotiate_encoding(state.encoding, advertised_encodings),
        hello_received?: true
    }
  end

  defp maybe_drain_after_ack(state) do
    case drain_delivery_queue(state) do
      {:ok, state} -> state
      {:error, _reason} -> state
    end
  end

  defp drain_delivery_queue(state) do
    case :queue.out(state.queued_deliveries) do
      {:empty, _queue} ->
        {:ok, state}

      {{:value, queued}, rest} ->
        if can_send_delivery?(state, queued.event_count, queued.stream_key) do
          state = %{state | queued_deliveries: rest}

          with {:ok, state} <-
                 send_delivery_now(
                   state,
                   queued.from,
                   queued.operation,
                   queued.payload,
                   queued.opts,
                   queued.event_count,
                   queued.stream_key
                 ) do
            drain_delivery_queue(state)
          end
        else
          {:ok, state}
        end
    end
  end

  defp can_send_delivery?(state, event_count, stream_key) do
    state.inflight_batches < max(state.max_inflight_batches, 1) and
      state.inflight_events + event_count <= max(state.max_inflight_events, 1) and
      delivery_stream_available?(state, stream_key)
  end

  defp increment_inflight(state, event_count, stream_key) do
    %{
      state
      | inflight_batches: state.inflight_batches + 1,
        inflight_events: state.inflight_events + max(event_count, 0),
        inflight_streams: maybe_track_inflight_stream(state.inflight_streams, stream_key)
    }
  end

  defp decrement_inflight(state, event_count, stream_key) do
    %{
      state
      | inflight_batches: max(state.inflight_batches - 1, 0),
        inflight_events: max(state.inflight_events - max(event_count, 0), 0),
        inflight_streams: maybe_release_inflight_stream(state.inflight_streams, stream_key)
    }
  end

  defp put_pending_request(state, request_id, from, timeout) do
    timer_ref = Process.send_after(self(), {:session_timeout, :request, request_id}, timeout)
    entry = %{from: from, timer_ref: timer_ref}
    %{state | pending_requests: Map.put(state.pending_requests, request_id, entry)}
  end

  defp put_pending_delivery(state, delivery_id, from, timer_ref, event_count, stream_key) do
    entry = %{from: from, timer_ref: timer_ref, event_count: event_count, stream_key: stream_key}
    %{state | pending_deliveries: Map.put(state.pending_deliveries, delivery_id, entry)}
  end

  defp fulfill_pending_request(state, request_id, result) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, pending_requests} ->
        %{state | pending_requests: pending_requests}

      {%{from: from, timer_ref: timer_ref}, pending_requests} ->
        _ = Process.cancel_timer(timer_ref)
        GenServer.reply(from, result)
        %{state | pending_requests: pending_requests}
    end
  end

  defp fulfill_pending_delivery(state, delivery_id, result) do
    case Map.pop(state.pending_deliveries, delivery_id) do
      {nil, pending_deliveries} ->
        %{state | pending_deliveries: pending_deliveries}

      {%{from: from, timer_ref: timer_ref, event_count: event_count, stream_key: stream_key},
       pending_deliveries} ->
        _ = Process.cancel_timer(timer_ref)
        GenServer.reply(from, result)

        state
        |> Map.put(:pending_deliveries, pending_deliveries)
        |> decrement_inflight(event_count, stream_key)
    end
  end

  defp fail_pending_request(state, request_id, reason) do
    state = fulfill_pending_request(state, request_id, {:error, reason})
    fail_and_disconnect(state, reason)
  end

  defp fail_pending_delivery(state, delivery_id, reason) do
    state = fulfill_pending_delivery(state, delivery_id, {:error, reason})
    fail_and_disconnect(state, reason)
  end

  defp fail_and_disconnect(state, reason) do
    state
    |> fail_all_pending(reason)
    |> disconnect()
  end

  defp fail_all_pending(state, reason) do
    pending_requests =
      Enum.reduce(state.pending_requests, %{}, fn {request_id,
                                                   %{from: from, timer_ref: timer_ref}},
                                                  acc ->
        _ = Process.cancel_timer(timer_ref)
        GenServer.reply(from, {:error, reason})
        Map.delete(acc, request_id)
      end)

    pending_deliveries =
      Enum.reduce(state.pending_deliveries, %{}, fn {delivery_id,
                                                     %{from: from, timer_ref: timer_ref}},
                                                    acc ->
        _ = Process.cancel_timer(timer_ref)
        GenServer.reply(from, {:error, reason})
        Map.delete(acc, delivery_id)
      end)

    %{
      state
      | pending_requests: pending_requests,
        pending_deliveries: pending_deliveries,
        queued_deliveries: :queue.new(),
        inflight_batches: 0,
        inflight_events: 0,
        inflight_streams: MapSet.new()
    }
  end

  defp delivery_stream_key("stream_batch", %{"stream_id" => stream_id}) when is_binary(stream_id),
    do: stream_id

  defp delivery_stream_key(_operation, _payload), do: nil

  defp delivery_stream_available?(_state, nil), do: true

  defp delivery_stream_available?(state, stream_key) do
    not MapSet.member?(state.inflight_streams, stream_key)
  end

  defp maybe_track_inflight_stream(streams, nil), do: streams
  defp maybe_track_inflight_stream(streams, stream_key), do: MapSet.put(streams, stream_key)

  defp maybe_release_inflight_stream(streams, nil), do: streams
  defp maybe_release_inflight_stream(streams, stream_key), do: MapSet.delete(streams, stream_key)

  defp parse_uri(url) when is_binary(url) do
    allow_insecure_transport = allow_insecure_transport?()

    case URI.parse(url) do
      %URI{scheme: "wss", host: host} = uri when is_binary(host) ->
        {:ok, uri}

      %URI{scheme: "ws", host: host} = uri when is_binary(host) ->
        if allow_insecure_transport do
          {:ok, uri}
        else
          {:error, :invalid_session_endpoint}
        end

      _ ->
        {:error, :invalid_session_endpoint}
    end
  end

  defp allow_insecure_transport? do
    Application.get_env(:elektrine, :messaging_federation, [])
    |> Config.allow_insecure_transport?()
  end

  defp open_socket(%URI{scheme: "ws", host: host, port: port}) do
    port = port || 80

    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, active: false, packet: :raw],
           @connect_timeout
         ) do
      {:ok, socket} -> {:ok, :gen_tcp, socket}
      {:error, reason} -> {:error, {:session_connect_failed, reason}}
    end
  end

  defp open_socket(%URI{scheme: "wss", host: host, port: port}) do
    port = port || 443

    ssl_opts = [
      :binary,
      active: false,
      packet: :raw,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :ssl.connect(String.to_charlist(host), port, ssl_opts, @connect_timeout) do
      {:ok, socket} -> {:ok, :ssl, socket}
      {:error, reason} -> {:error, {:session_connect_failed, reason}}
    end
  end

  defp websocket_handshake(peer, transport, socket, %URI{host: host, port: port} = uri) do
    request_path = uri.path || "/"
    query_string = uri.query || ""
    request_target = request_target(request_path, query_string)
    websocket_key = :crypto.strong_rand_bytes(16) |> Base.encode64()

    headers =
      peer
      |> Federation.signed_headers("GET", request_path, query_string, "")
      |> Enum.reject(fn {key, _value} -> String.downcase(key) == "content-type" end)
      |> Enum.concat([
        {"host", host_header(host, uri.scheme, port)},
        {"connection", "Upgrade"},
        {"upgrade", "websocket"},
        {"sec-websocket-version", "13"},
        {"sec-websocket-key", websocket_key},
        {"sec-websocket-protocol", @subprotocol}
      ])

    request = [
      "GET ",
      request_target,
      " HTTP/1.1\r\n",
      Enum.map(headers, fn {key, value} -> [key, ": ", value, "\r\n"] end),
      "\r\n"
    ]

    with :ok <- socket_send(transport, socket, request),
         {:ok, response} <- recv_http_response(transport, socket, <<>>, @connect_timeout) do
      {:ok, Map.put(response, :websocket_key, websocket_key), request_path, query_string}
    end
  end

  defp validate_handshake_response(%{
         status: 101,
         headers: headers,
         rest: rest,
         websocket_key: key
       }) do
    accept =
      key
      |> Kernel.<>(@websocket_magic)
      |> then(&:crypto.hash(:sha, &1))
      |> Base.encode64()

    case {header_value(headers, "sec-websocket-accept"),
          header_value(headers, "sec-websocket-protocol")} do
      {^accept, nil} -> {:ok, rest}
      {^accept, @subprotocol} -> {:ok, rest}
      _ -> {:error, :invalid_session_handshake}
    end
  end

  defp validate_handshake_response(%{status: status}) when is_integer(status) do
    {:error, {:http_error, status}}
  end

  defp send_request_frame(state, operation, request_id, payload) do
    send_data_frame(state, %{"op" => operation, "request_id" => request_id, "payload" => payload})
  end

  defp send_delivery_frame(state, operation, delivery_id, payload) do
    with {:ok, normalized_payload} <- normalize_delivery_payload(operation, payload, delivery_id) do
      send_data_frame(state, %{
        "op" => operation,
        "delivery_id" => delivery_id,
        "payload" => normalized_payload
      })
    end
  end

  defp send_data_frame(state, payload) do
    frame =
      case state.encoding do
        :cbor -> encode_client_frame(:binary, CBOR.encode(payload))
        _ -> encode_client_frame(:text, Jason.encode!(payload))
      end

    socket_send(state.transport, state.socket, frame)
  end

  defp normalize_delivery_payload(operation, payload, delivery_id)
       when operation in ["stream_batch", "deliver_ephemeral"] and is_map(payload) do
    {:ok,
     payload
     |> Map.put("version", 1)
     |> Map.put("delivery_id", delivery_id)}
  end

  defp normalize_delivery_payload(_operation, payload, _delivery_id) when is_map(payload),
    do: {:ok, payload}

  defp normalize_delivery_payload(_operation, _payload, _delivery_id),
    do: {:error, :invalid_payload}

  defp recv_http_response(transport, socket, buffer, timeout) do
    case :binary.match(buffer, "\r\n\r\n") do
      {index, 4} ->
        header_block = binary_part(buffer, 0, index)
        rest = binary_part(buffer, index + 4, byte_size(buffer) - index - 4)
        parse_http_response(header_block, rest)

      :nomatch ->
        case socket_recv(transport, socket, timeout) do
          {:ok, data} -> recv_http_response(transport, socket, buffer <> data, timeout)
          {:error, reason} -> {:error, {:session_handshake_failed, reason}}
        end
    end
  end

  defp parse_http_response(header_block, rest) do
    [status_line | header_lines] = String.split(header_block, "\r\n", trim: true)

    with ["HTTP/1.1", status_code | _] <- String.split(status_line, " ", parts: 3),
         {status, ""} <- Integer.parse(status_code) do
      headers =
        Enum.reduce(header_lines, %{}, fn line, acc ->
          case String.split(line, ":", parts: 2) do
            [key, value] ->
              Map.put(acc, String.downcase(String.trim(key)), String.trim(value))

            _ ->
              acc
          end
        end)

      {:ok, %{status: status, headers: headers, rest: rest}}
    else
      _ -> {:error, :invalid_session_handshake}
    end
  end

  defp decode_text_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, :invalid_session_frame}
    end
  end

  defp decode_binary_payload(payload) when is_binary(payload) do
    case CBOR.decode(payload) do
      {:ok, decoded, ""} -> {:ok, decoded}
      _ -> {:error, :invalid_session_frame}
    end
  end

  defp activate_socket(%{transport: :gen_tcp, socket: socket}) when not is_nil(socket) do
    :inet.setopts(socket, active: :once)
  end

  defp activate_socket(%{transport: :ssl, socket: socket}) when not is_nil(socket) do
    :ssl.setopts(socket, active: :once)
  end

  defp activate_socket(_state), do: :ok

  defp encode_client_frame(opcode, payload)
       when opcode in [:text, :binary] and is_binary(payload) do
    opcode_byte = if(opcode == :text, do: 0x1, else: 0x2)
    mask = :crypto.strong_rand_bytes(4)
    masked_payload = mask_payload(payload, mask)
    [<<0x80 ||| opcode_byte>>, length_prefix(byte_size(payload), true), mask, masked_payload]
  end

  defp encode_client_control(opcode, payload)
       when opcode in [:pong, :ping] and is_binary(payload) do
    opcode_byte = if(opcode == :ping, do: 0x9, else: 0xA)
    mask = :crypto.strong_rand_bytes(4)
    masked_payload = mask_payload(payload, mask)
    [<<0x80 ||| opcode_byte>>, length_prefix(byte_size(payload), true), mask, masked_payload]
  end

  defp decode_server_frame(<<>>), do: :more

  defp decode_server_frame(<<first, second, rest::binary>>) do
    fin? = (first &&& 0x80) == 0x80
    opcode = first &&& 0x0F
    masked? = (second &&& 0x80) == 0x80
    payload_length = second &&& 0x7F

    with true <- fin?,
         {:ok, payload_length, rest} <- parse_payload_length(payload_length, rest),
         {:ok, mask, rest} <- parse_mask(masked?, rest),
         {:ok, payload, rest} <- parse_payload(rest, payload_length) do
      payload = if masked?, do: mask_payload(payload, mask), else: payload

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

  defp parse_mask(true, <<mask::binary-size(4), rest::binary>>), do: {:ok, mask, rest}
  defp parse_mask(true, _buffer), do: :more
  defp parse_mask(false, rest), do: {:ok, nil, rest}

  defp parse_payload(buffer, payload_length) when byte_size(buffer) < payload_length, do: :more

  defp parse_payload(buffer, payload_length) do
    payload = binary_part(buffer, 0, payload_length)
    rest = binary_part(buffer, payload_length, byte_size(buffer) - payload_length)
    {:ok, payload, rest}
  end

  defp response_reason(code) when is_binary(code) do
    case Federation.error_reason(code) do
      nil -> :session_transport_failed
      reason -> reason
    end
  end

  defp response_reason(_code), do: :session_transport_failed

  defp request_target(path, ""), do: path
  defp request_target(path, query_string), do: path <> "?" <> query_string

  defp host_header(host, "ws", port) when port in [nil, 80], do: host
  defp host_header(host, "wss", port) when port in [nil, 443], do: host
  defp host_header(host, _scheme, port), do: "#{host}:#{port}"

  defp socket_send(:gen_tcp, socket, data), do: :gen_tcp.send(socket, data)
  defp socket_send(:ssl, socket, data), do: :ssl.send(socket, data)

  defp socket_recv(:gen_tcp, socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)
  defp socket_recv(:ssl, socket, timeout), do: :ssl.recv(socket, 0, timeout)

  defp close_socket(%{socket: nil}), do: :ok
  defp close_socket(%{socket: socket, transport: :gen_tcp}), do: :gen_tcp.close(socket)
  defp close_socket(%{socket: socket, transport: :ssl}), do: :ssl.close(socket)
  defp close_socket(_state), do: :ok

  defp disconnect(state) do
    _ = close_socket(state)

    %{
      state
      | socket: nil,
        transport: nil,
        request_path: nil,
        query_string: nil,
        buffer: <<>>,
        inflight_batches: 0,
        inflight_events: 0,
        hello_received?: false
    }
  end

  defp preferred_encoding(peer) when is_map(peer) do
    features =
      Map.get(peer, :features) || Map.get(peer, "features") || %{}

    case Map.get(features, "binary_event_batches") do
      true -> :cbor
      "true" -> :cbor
      1 -> :cbor
      _ -> :json
    end
  end

  defp preferred_encoding(_peer), do: :json

  defp negotiate_encoding(current, advertised_encodings) when is_list(advertised_encodings) do
    cond do
      current == :cbor and "cbor" in advertised_encodings -> :cbor
      "json" in advertised_encodings -> :json
      "cbor" in advertised_encodings -> :cbor
      true -> current
    end
  end

  defp notify(%__MODULE__{peer: peer}, message) do
    notify(peer, message)
  end

  defp notify(peer, message) when is_map(peer) do
    case Map.get(peer, :debug_notify) || Map.get(peer, "debug_notify") do
      pid when is_pid(pid) -> send(pid, {:federation_session_client, message})
      _ -> :ok
    end
  end

  defp notify(_peer, _message), do: :ok

  defp header_value(headers, key) when is_map(headers), do: Map.get(headers, String.downcase(key))

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

  defp parse_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp parse_positive_integer(_value, default), do: default

  defp delivery_event_count("stream_batch", %{"events" => events}) when is_list(events),
    do: max(length(events), 1)

  defp delivery_event_count("deliver_ephemeral", %{"items" => items}) when is_list(items),
    do: max(length(items), 1)

  defp delivery_event_count(_operation, _payload), do: 1
end
