defmodule Elektrine.Messaging.FederationSessionWebSock do
  @moduledoc false
  @behaviour WebSock

  alias Elektrine.Messaging.Federation

  @hello_frame %{
    "op" => "hello",
    "protocol" => "arblarg",
    "transport" => "session_websocket",
    "session_version" => 1,
    "mode" => "stream_session",
    "encodings" => ["json", "cbor"]
  }

  @impl true
  def init(%{} = state) do
    hello =
      @hello_frame
      |> Map.put("limits", Federation.discovery_limits_for_transport())
      |> Map.put("transport_profiles", Federation.transport_profiles_for_transport())
      |> Map.put("flow_control", Federation.session_flow_control_for_transport())
      |> encode_frame(:text)

    {:push, hello, state}
  end

  @impl true
  def handle_in({payload, [opcode: opcode]}, %{} = state) when opcode in [:text, :binary] do
    {encoding, decoded_payload} = decode_frame_payload(payload, opcode)

    response =
      case decoded_payload do
        {:ok, %{"op" => op} = request} when is_binary(op) ->
          dispatch_frame(op, request, state, encoding)

        {:ok, _} ->
          error_frame(nil, :invalid_session_frame, encoding)

        {:error, reason} ->
          error_frame(nil, reason, encoding)
      end

    {:push, response, state}
  end

  def handle_in({_payload, _meta}, state) do
    {:push, error_frame(nil, :invalid_session_frame, :json), state}
  end

  @impl true
  def handle_control({_payload, _meta}, state), do: {:ok, state}

  @impl true
  def handle_info(_message, state), do: {:ok, state}

  defp dispatch_frame("stream_batch", %{"delivery_id" => delivery_id} = request, state, encoding)
       when is_binary(delivery_id) do
    dispatch_delivery_request("stream_batch", request, state, delivery_id, encoding)
  end

  defp dispatch_frame(
         "deliver_ephemeral",
         %{"delivery_id" => delivery_id} = request,
         state,
         encoding
       )
       when is_binary(delivery_id) do
    dispatch_delivery_request("deliver_ephemeral", request, state, delivery_id, encoding)
  end

  defp dispatch_frame(op, %{"request_id" => request_id} = request, state, encoding)
       when is_binary(op) and is_binary(request_id) do
    dispatch_control_request(op, request, state, request_id, encoding)
  end

  defp dispatch_frame(_op, %{"delivery_id" => delivery_id}, _state, encoding)
       when is_binary(delivery_id) do
    ack_error_frame(delivery_id, :unsupported_operation, encoding)
  end

  defp dispatch_frame(_op, %{"request_id" => request_id}, _state, encoding)
       when is_binary(request_id) do
    error_frame(request_id, :unsupported_operation, encoding)
  end

  defp dispatch_frame(_op, _request, _state, encoding) do
    error_frame(nil, :invalid_session_frame, encoding)
  end

  defp dispatch_control_request("events_batch", request, state, request_id, encoding) do
    remote_domain = state.remote_domain

    case Federation.receive_event_batch(Map.get(request, "payload"), remote_domain) do
      {:ok, payload} -> ok_frame(request_id, payload, encoding)
      {:error, reason} -> error_frame(request_id, reason, encoding)
    end
  end

  defp dispatch_control_request("ephemeral_batch", request, state, request_id, encoding) do
    remote_domain = state.remote_domain

    case Federation.receive_ephemeral_batch(Map.get(request, "payload"), remote_domain) do
      {:ok, payload} -> ok_frame(request_id, payload, encoding)
      {:error, reason} -> error_frame(request_id, reason, encoding)
    end
  end

  defp dispatch_control_request("stream_events", request, state, request_id, encoding) do
    payload = Map.get(request, "payload") || %{}

    case Map.get(payload, "stream_id") do
      stream_id when is_binary(stream_id) ->
        response =
          Federation.export_stream_events(stream_id,
            after_sequence: payload["after_sequence"] || 0,
            limit: payload["limit"] || 128,
            peer: Map.get(state, :peer)
          )

        ok_frame(request_id, response, encoding)

      _ ->
        error_frame(request_id, :invalid_payload, encoding)
    end
  end

  defp dispatch_control_request("snapshot", request, state, request_id, encoding) do
    payload = Map.get(request, "payload") || %{}

    with server_id when is_integer(server_id) <- parse_server_id(payload["server_id"]),
         {:ok, snapshot} <-
           Federation.build_server_snapshot(server_id, peer: Map.get(state, :peer)) do
      ok_frame(request_id, snapshot, encoding)
    else
      nil -> error_frame(request_id, :invalid_server_id, encoding)
      {:error, reason} -> error_frame(request_id, reason, encoding)
      _ -> error_frame(request_id, :invalid_server_id, encoding)
    end
  end

  defp dispatch_control_request("ping", _request, _state, request_id, encoding) do
    ok_frame(request_id, %{"status" => "pong"}, encoding)
  end

  defp dispatch_control_request(_op, _request, _state, request_id, encoding) do
    error_frame(request_id, :unsupported_operation, encoding)
  end

  defp dispatch_delivery_request("stream_batch", request, state, delivery_id, encoding) do
    remote_domain = state.remote_domain
    payload = Map.get(request, "payload") || %{}

    case Federation.receive_session_stream_batch(payload, remote_domain, delivery_id) do
      {:ok, ack_payload} -> ack_frame(delivery_id, ack_payload, encoding)
      {:error, reason} -> ack_error_frame(delivery_id, reason, encoding)
    end
  end

  defp dispatch_delivery_request("deliver_ephemeral", request, state, delivery_id, encoding) do
    remote_domain = state.remote_domain
    payload = Map.get(request, "payload") || %{}

    case Federation.receive_session_ephemeral_batch(payload, remote_domain, delivery_id) do
      {:ok, ack_payload} -> ack_frame(delivery_id, ack_payload, encoding)
      {:error, reason} -> ack_error_frame(delivery_id, reason, encoding)
    end
  end

  defp ok_frame(request_id, payload, encoding) do
    encode_frame(
      %{
        "op" => "response",
        "request_id" => request_id,
        "status" => "ok",
        "payload" => payload
      },
      encoding
    )
  end

  defp error_frame(request_id, reason, encoding) do
    encode_frame(
      %{
        "op" => "response",
        "request_id" => request_id,
        "status" => "error",
        "code" => Federation.error_code(reason)
      },
      encoding
    )
  end

  defp ack_frame(delivery_id, payload, encoding) do
    encode_frame(
      %{
        "op" => "ack",
        "delivery_id" => delivery_id,
        "status" => "ok",
        "payload" => payload
      },
      encoding
    )
  end

  defp ack_error_frame(delivery_id, reason, encoding) do
    encode_frame(
      %{
        "op" => "ack",
        "delivery_id" => delivery_id,
        "status" => "error",
        "code" => Federation.error_code(reason)
      },
      encoding
    )
  end

  defp decode_frame_payload(payload, :text) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> {:json, {:ok, decoded}}
      _ -> {:json, {:error, :invalid_session_frame}}
    end
  end

  defp decode_frame_payload(payload, :binary) when is_binary(payload) do
    case CBOR.decode(payload) do
      {:ok, decoded, ""} -> {:cbor, {:ok, decoded}}
      _ -> {:cbor, {:error, :invalid_session_frame}}
    end
  end

  defp decode_frame_payload(_payload, _opcode), do: {:json, {:error, :invalid_session_frame}}

  defp encode_frame(payload, :cbor), do: {:binary, CBOR.encode(payload)}
  defp encode_frame(payload, :json), do: {:text, Jason.encode!(payload)}
  defp encode_frame(payload, :text), do: {:text, Jason.encode!(payload)}

  defp parse_server_id(value) when is_integer(value), do: value

  defp parse_server_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_server_id(_value), do: nil
end
