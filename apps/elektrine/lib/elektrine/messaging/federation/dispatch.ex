defmodule Elektrine.Messaging.Federation.Dispatch do
  @moduledoc false

  import Elektrine.Messaging.Federation.Utils
  require Logger

  alias Elektrine.Messaging.{FederationOutboxEvent, FederationOutboxWorker}
  alias Elektrine.Repo

  def enqueue_outbox_event(event, target_domains \\ :all, context)

  def enqueue_outbox_event(event, :all, context) when is_map(event) and is_map(context) do
    peer_domains =
      call(context, :outgoing_peers, [])
      |> Enum.map(&String.downcase(&1.domain))
      |> Enum.uniq()

    do_enqueue_outbox_event(event, peer_domains, context)
  end

  def enqueue_outbox_event(event, target_domains, context)
      when is_map(event) and is_list(target_domains) and is_map(context) do
    filtered_domains =
      target_domains
      |> Enum.map(&normalize_optional_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.filter(fn domain -> match?(%{}, call(context, :outgoing_peer, [domain])) end)
      |> Enum.uniq()

    do_enqueue_outbox_event(event, filtered_domains, context)
  end

  def enqueue_outbox_event(event, _target_domains, context) when is_map(event) and is_map(context) do
    enqueue_outbox_event(event, :all, context)
  end

  def fanout_ephemeral_batch(_items, [], _context), do: :ok

  def fanout_ephemeral_batch(items, domains, context)
      when is_list(items) and is_list(domains) and is_map(context) do
    domains
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.each(fn domain ->
      case call(context, :outgoing_peer, [domain]) do
        %{} = peer ->
          items
          |> Enum.chunk_every(call(context, :peer_ephemeral_limit, [peer]))
          |> Enum.each(fn item_chunk ->
            _ = call(context, :push_ephemeral_batch_to_peer, [peer, item_chunk])
          end)

        _ ->
          :ok
      end
    end)

    :ok
  end

  def ephemeral_stream_id(event_type, payload)

  def ephemeral_stream_id(event_type, payload)
      when event_type in ["typing.start", "typing.stop"] and is_map(payload) do
    with channel_id when is_binary(channel_id) <- event_channel_id(payload),
         fragment when is_binary(fragment) <- actor_stream_fragment(payload["actor"]) do
      "typing:#{channel_id}:#{fragment}"
    else
      _ -> nil
    end
  end

  def ephemeral_stream_id(event_type, payload)
      when event_type in ["presence.update"] and is_map(payload) do
    with server_id when is_binary(server_id) <- event_server_id(payload),
         fragment when is_binary(fragment) <-
           actor_stream_fragment(get_in(payload, ["presence", "actor"])) do
      "presence:#{server_id}:#{fragment}"
    else
      _ -> nil
    end
  end

  def ephemeral_stream_id(_event_type, _payload), do: nil

  defp do_enqueue_outbox_event(_event, [], _context), do: :ok

  defp do_enqueue_outbox_event(event, peer_domains, context) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      event_id: event["event_id"],
      event_type: event["event_type"],
      stream_id: event["stream_id"],
      sequence: parse_int(event["sequence"], 0),
      payload: event,
      target_domains: peer_domains,
      delivered_domains: [],
      attempt_count: 0,
      max_attempts: call(context, :outbox_max_attempts, []),
      status: "pending",
      next_retry_at: now,
      partition_month: call(context, :outbox_partition_month, [now])
    }

    case %FederationOutboxEvent{} |> FederationOutboxEvent.changeset(attrs) |> Repo.insert() do
      {:ok, outbox_event} ->
        _ = FederationOutboxWorker.enqueue(outbox_event.id)
        :ok

      {:error, %Ecto.Changeset{errors: [event_id: _]}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue federation outbox event: #{inspect(reason)}")
        :ok
    end
  end

  defp actor_stream_fragment(actor_payload) when is_map(actor_payload) do
    actor_hint =
      normalize_optional_string(
        actor_payload["uri"] ||
          actor_payload["handle"] ||
          actor_payload["id"] ||
          actor_payload["actor"]
      ) ||
        case {
          normalize_optional_string(actor_payload["username"]),
          normalize_optional_string(actor_payload["domain"])
        } do
          {username, domain} when is_binary(username) and is_binary(domain) ->
            "#{username}@#{domain}"

          _ ->
            nil
        end

    case actor_hint do
      hint when is_binary(hint) ->
        :crypto.hash(:sha256, hint)
        |> Base.url_encode64(padding: false)
        |> binary_part(0, 12)

      _ ->
        nil
    end
  end

  defp actor_stream_fragment(_actor_payload), do: nil

  defp event_server_id(data) when is_map(data) do
    refs = data["refs"] || %{}
    get_in(data, ["server", "id"]) || refs["server_id"]
  end

  defp event_server_id(_data), do: nil

  defp event_channel_id(data) when is_map(data) do
    refs = data["refs"] || %{}
    get_in(data, ["channel", "id"]) || refs["channel_id"]
  end

  defp event_channel_id(_data), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
