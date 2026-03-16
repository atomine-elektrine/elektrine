defmodule Elektrine.Messaging.Federation.Config do
  @moduledoc false

  alias Elektrine.Messaging.ArblargSDK

  def delivery_concurrency(config) when is_list(config) do
    Keyword.get(config, :delivery_concurrency, 6)
  end

  def outbound_events_url(peer) do
    peer.event_endpoint || "#{peer.base_url}/_arblarg/events"
  end

  def outbound_events_batch_url(peer) do
    peer.events_batch_endpoint || "#{peer.base_url}/_arblarg/events/batch"
  end

  def outbound_ephemeral_url(peer) do
    peer.ephemeral_endpoint || "#{peer.base_url}/_arblarg/ephemeral"
  end

  def outbound_sync_url(peer) do
    peer.sync_endpoint || "#{peer.base_url}/_arblarg/sync"
  end

  def outbound_stream_events_url(peer, query_string \\ "") do
    base = peer.stream_events_endpoint || "#{peer.base_url}/_arblarg/streams/events"

    case normalize_optional_string(query_string) do
      nil -> base
      query -> base <> "?" <> query
    end
  end

  def outbound_session_websocket_url(peer) do
    allow_insecure_transport =
      Application.get_env(:elektrine, :messaging_federation, [])
      |> allow_insecure_transport?()

    outbound_session_websocket_url(peer, allow_insecure_transport)
  end

  def outbound_session_websocket_url(peer, allow_insecure_transport)
      when is_boolean(allow_insecure_transport) do
    explicit_endpoint =
      peer
      |> value_from(:session_websocket_endpoint)
      |> normalize_optional_string()

    cond do
      valid_session_websocket_url?(explicit_endpoint, allow_insecure_transport) ->
        explicit_endpoint

      is_binary(normalize_optional_string(value_from(peer, :base_url))) ->
        case peer
             |> value_from(:base_url)
             |> normalize_optional_string()
             |> websocket_base_url(allow_insecure_transport) do
          base when is_binary(base) -> base <> "/_arblarg/session"
          _ -> nil
        end

      true ->
        nil
    end
  end

  def outbound_snapshot_url(peer, remote_server_id) do
    case peer.snapshot_endpoint_template do
      template when is_binary(template) ->
        if String.contains?(template, "{server_id}") do
          String.replace(template, "{server_id}", Integer.to_string(remote_server_id))
        else
          template
        end

      _ ->
        "#{peer.base_url}/_arblarg/servers/#{remote_server_id}/snapshot"
    end
  end

  def delivery_timeout_ms(config) when is_list(config) do
    Keyword.get(config, :delivery_timeout_ms, 12_000)
  end

  def outbox_max_attempts(config) when is_list(config) do
    Keyword.get(config, :outbox_max_attempts, 8)
  end

  def delivery_batch_size(config) when is_list(config) do
    Keyword.get(config, :delivery_batch_size, 32)
  end

  def outbox_base_backoff_seconds(config) when is_list(config) do
    Keyword.get(config, :outbox_base_backoff_seconds, 5)
  end

  def outbox_backoff_seconds(config, attempt_count) when is_integer(attempt_count) do
    base = outbox_base_backoff_seconds(config)
    trunc(min(base * :math.pow(2, max(attempt_count - 1, 0)), 900))
  end

  def outbox_partition_month(%DateTime{} = datetime) do
    Date.new!(datetime.year, datetime.month, 1)
  end

  def event_retention_days(config) when is_list(config) do
    Keyword.get(config, :event_retention_days, 14)
  end

  def outbox_retention_days(config) when is_list(config) do
    Keyword.get(config, :outbox_retention_days, 30)
  end

  def replay_nonce_ttl_seconds(config, default_clock_skew_seconds) when is_list(config) do
    max(clock_skew_seconds(config, default_clock_skew_seconds) * 2, 600)
  end

  def stream_replay_limit(config) when is_list(config) do
    Keyword.get(config, :stream_replay_limit, 128)
  end

  def incoming_batch_limit(config) when is_list(config) do
    Keyword.get(config, :incoming_batch_limit, 128)
  end

  def incoming_ephemeral_limit(config) when is_list(config) do
    Keyword.get(config, :incoming_ephemeral_limit, 256)
  end

  def snapshot_channel_limit(config) when is_list(config) do
    Keyword.get(config, :snapshot_channel_limit, 500)
  end

  def snapshot_message_limit(config) when is_list(config) do
    Keyword.get(config, :snapshot_message_limit, 5_000)
  end

  def snapshot_governance_limit(config) when is_list(config) do
    Keyword.get(config, :snapshot_governance_limit, 5_000)
  end

  def discovery_ttl_seconds(config) when is_list(config) do
    Keyword.get(config, :discovery_ttl_seconds, 3_600)
  end

  def session_max_inflight_batches(config) when is_list(config) do
    Keyword.get(config, :session_max_inflight_batches, 8)
  end

  def session_max_inflight_events(config) when is_list(config) do
    Keyword.get(config, :session_max_inflight_events, 256)
  end

  def discovery_stale_grace_seconds(config) when is_list(config) do
    Keyword.get(config, :discovery_stale_grace_seconds, 86_400)
  end

  def presence_ttl_seconds(config) when is_list(config) do
    Keyword.get(config, :presence_ttl_seconds, 120)
  end

  def allow_insecure_transport?(config) when is_list(config) do
    Keyword.get(config, :allow_insecure_http_transport, false)
  end

  def clock_skew_seconds(config, default_clock_skew_seconds) when is_list(config) do
    Keyword.get(config, :clock_skew_seconds, default_clock_skew_seconds)
  end

  def local_base_url(config, local_domain) when is_binary(local_domain) do
    configured =
      config
      |> Keyword.get(:base_url)
      |> normalize_optional_string()

    configured || infer_local_base_url(local_domain)
  end

  def local_identity_key_id(config) when is_list(config) do
    config |> Keyword.get(:identity_key_id, "default") |> to_string()
  end

  def local_identity_discovery_identity(identity_keys, key_id) when is_binary(key_id) do
    keys =
      identity_keys
      |> Enum.map(fn key ->
        %{
          "id" => key.id,
          "algorithm" => ArblargSDK.signature_algorithm(),
          "public_key" => Base.url_encode64(key.public_key, padding: false)
        }
      end)

    %{
      "algorithm" => ArblargSDK.signature_algorithm(),
      "current_key_id" => key_id,
      "keys" => keys
    }
  end

  def local_identity_keys(config, key_id, local_domain, federation_enabled, prod_environment)
      when is_list(config) and is_binary(key_id) and is_binary(local_domain) and
             is_boolean(federation_enabled) and is_boolean(prod_environment) do
    configured =
      config
      |> Keyword.get(:identity_keys, [])
      |> Enum.map(&normalize_identity_key/1)
      |> Enum.reject(&is_nil/1)

    cond do
      configured != [] ->
        configured

      is_binary(normalize_optional_string(config |> Keyword.get(:identity_shared_secret))) ->
        secret = config |> Keyword.get(:identity_shared_secret)
        {public_key, private_key} = ArblargSDK.derive_keypair_from_secret(secret)
        [%{id: key_id, public_key: public_key, private_key: private_key}]

      true ->
        if federation_enabled and prod_environment do
          raise ArgumentError,
                "messaging federation requires explicit identity keys in production; " <>
                  "configure :identity_keys or :identity_shared_secret"
        end

        {public_key, private_key} = ArblargSDK.derive_keypair_from_secret(local_domain)
        [%{id: key_id, public_key: public_key, private_key: private_key}]
    end
  end

  def official_relay_operator(config) when is_list(config) do
    config
    |> Keyword.get(:official_relay_operator, "Community-operated")
    |> normalize_relay_operator_label()
  end

  def discovery_official_relays(config) when is_list(config) do
    config
    |> Keyword.get(:official_relays, [])
    |> Enum.map(&normalize_discovery_relay/1)
    |> Enum.reject(&is_nil/1)
  end

  def configured_peers(config, allow_insecure_transport) when is_list(config) do
    config
    |> Keyword.get(:peers, [])
    |> Enum.map(&normalize_peer(&1, allow_insecure_transport))
    |> Enum.reject(&is_nil/1)
  end

  def normalize_peer_config(peer, allow_insecure_transport) do
    normalize_peer(peer, allow_insecure_transport)
  end

  def infer_local_base_url(domain) when is_binary(domain) do
    is_tunnel = String.contains?(domain, ".") and not String.starts_with?(domain, "localhost")
    scheme = if System.get_env("MIX_ENV") == "prod" or is_tunnel, do: "https", else: "http"
    port = System.get_env("PORT") || "4000"

    if scheme == "https" or port in ["80", "443"] or is_tunnel do
      "#{scheme}://#{domain}"
    else
      "#{scheme}://#{domain}:#{port}"
    end
  end

  defp normalize_identity_key(key) when is_list(key), do: normalize_identity_key(Map.new(key))

  defp normalize_identity_key(key) when is_map(key) do
    id = normalize_optional_string(value_from(key, :id))
    secret = normalize_optional_string(value_from(key, :secret))
    public_key_encoded = normalize_optional_string(value_from(key, :public_key))
    private_key_encoded = normalize_optional_string(value_from(key, :private_key))

    cond do
      !is_binary(id) ->
        nil

      is_binary(secret) ->
        {public_key, private_key} = ArblargSDK.derive_keypair_from_secret(secret)
        %{id: id, public_key: public_key, private_key: private_key}

      true ->
        case decode_or_derive_identity_keys(public_key_encoded, private_key_encoded) do
          {:ok, public_key, private_key} ->
            %{id: id, public_key: public_key, private_key: private_key}

          _ ->
            nil
        end
    end
  end

  defp normalize_identity_key(_), do: nil

  defp decode_or_derive_identity_keys(public_key_encoded, private_key_encoded) do
    private_key_result = decode_key_material(private_key_encoded)
    public_key_result = decode_key_material(public_key_encoded)

    case {public_key_result, private_key_result} do
      {{:ok, public_key}, {:ok, private_key}} ->
        {:ok, public_key, private_key}

      {:error, {:ok, private_key}} ->
        {public_key, _} = :crypto.generate_key(:eddsa, :ed25519, private_key)
        {:ok, public_key, private_key}

      {{:ok, public_key}, :error} ->
        {:ok, public_key, nil}

      _ ->
        :error
    end
  end

  defp normalize_discovery_relay(relay) when is_binary(relay) do
    url = normalize_optional_string(relay)

    if is_binary(url) do
      %{"url" => url}
    else
      nil
    end
  end

  defp normalize_discovery_relay(relay) when is_map(relay) do
    url = normalize_optional_string(value_from(relay, :url))
    name = normalize_optional_string(value_from(relay, :name))
    websocket_url = normalize_optional_string(value_from(relay, :websocket_url))
    region = normalize_optional_string(value_from(relay, :region))

    if is_binary(url) do
      relay_doc = %{"url" => url}

      relay_doc =
        if is_binary(name) do
          Map.put(relay_doc, "name", name)
        else
          relay_doc
        end

      relay_doc =
        if is_binary(websocket_url) do
          Map.put(relay_doc, "websocket_url", websocket_url)
        else
          relay_doc
        end

      if is_binary(region) do
        Map.put(relay_doc, "region", region)
      else
        relay_doc
      end
    else
      nil
    end
  end

  defp normalize_discovery_relay(_), do: nil

  defp normalize_relay_operator_label(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "Community-operated"
      label -> label
    end
  end

  defp normalize_peer(peer, allow_insecure_transport) when is_map(peer) do
    domain = value_from(peer, :domain)
    base_url = value_from(peer, :base_url)
    shared_secret = value_from(peer, :shared_secret)
    keys = normalize_peer_keys(value_from(peer, :keys, []), shared_secret)
    compatibility_claims =
      normalize_peer_compatibility_claims(value_from(peer, :compatibility_claims, []))

    extensions = normalize_peer_extensions(value_from(peer, :extensions, []))

    supported_event_types =
      normalize_peer_supported_event_types(value_from(peer, :supported_event_types, []))

    limits = normalize_peer_limits(value_from(peer, :limits))

    transport_profiles =
      normalize_peer_transport_profiles(value_from(peer, :transport_profiles))

    features =
      value_from(peer, :features)
      |> normalize_peer_features()
      |> maybe_put_peer_capability("compatibility_claims", compatibility_claims)
      |> maybe_put_peer_capability("extensions", extensions)
      |> maybe_put_peer_capability("supported_event_types", supported_event_types)
      |> maybe_put_peer_capability("limits", limits)
      |> maybe_put_peer_capability("transport_profiles", transport_profiles)

    normalized_base_url =
      if is_binary(base_url) do
        String.trim_trailing(base_url, "/")
      else
        nil
      end

    if !is_binary(domain) or !is_binary(normalized_base_url) or Enum.empty?(keys) or
         !valid_peer_base_url?(normalized_base_url, allow_insecure_transport) do
      nil
    else
      %{
        domain: domain,
        base_url: normalized_base_url,
        shared_secret: shared_secret,
        keys: keys,
        active_outbound_key_id: resolve_active_outbound_key_id(peer, keys),
        allow_incoming: value_from(peer, :allow_incoming, true) == true,
        allow_outgoing: value_from(peer, :allow_outgoing, true) == true,
        compatibility_claims: compatibility_claims,
        extensions: extensions,
        supported_event_types: supported_event_types,
        features: features,
        event_endpoint: normalize_optional_string(value_from(peer, :event_endpoint)),
        events_batch_endpoint:
          normalize_optional_string(value_from(peer, :events_batch_endpoint)),
        ephemeral_endpoint: normalize_optional_string(value_from(peer, :ephemeral_endpoint)),
        sync_endpoint: normalize_optional_string(value_from(peer, :sync_endpoint)),
        directory_endpoint: normalize_optional_string(value_from(peer, :directory_endpoint)),
        stream_events_endpoint:
          normalize_optional_string(value_from(peer, :stream_events_endpoint)),
        session_websocket_endpoint:
          normalize_optional_string(value_from(peer, :session_websocket_endpoint)),
        snapshot_endpoint_template:
          normalize_optional_string(value_from(peer, :snapshot_endpoint_template))
      }
    end
  end

  defp normalize_peer(peer, allow_insecure_transport) when is_list(peer) do
    normalize_peer(Map.new(peer), allow_insecure_transport)
  end

  defp normalize_peer(_, _), do: nil

  defp valid_peer_base_url?(base_url, allow_insecure_transport) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        true

      %URI{scheme: "http", host: host} when is_binary(host) and host != "" ->
        allow_insecure_transport == true

      _ ->
        false
    end
  end

  defp valid_peer_base_url?(_, _), do: false

  defp normalize_peer_features(features) when is_map(features) do
    normalize_peer_capability_document(features)
  end

  defp normalize_peer_features(_features), do: %{}

  defp normalize_peer_compatibility_claims(claims) when is_list(claims) do
    claims
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_peer_compatibility_claims(_claims), do: []

  defp normalize_peer_extensions(extensions) when is_list(extensions) do
    extensions
    |> Enum.map(&normalize_peer_extension/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_peer_extensions(_extensions), do: []

  defp normalize_peer_extension(extension) when is_binary(extension) do
    case normalize_optional_string(extension) do
      nil -> nil
      urn -> %{"urn" => urn}
    end
  end

  defp normalize_peer_extension(extension) when is_map(extension) do
    normalized = normalize_peer_capability_document(extension)

    case normalize_optional_string(value_from(normalized, :urn)) do
      nil -> nil
      urn -> Map.put(normalized, "urn", urn)
    end
  end

  defp normalize_peer_extension(_extension), do: nil

  defp normalize_peer_supported_event_types(event_types) when is_list(event_types) do
    event_types
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&ArblargSDK.canonical_event_type/1)
    |> Enum.uniq()
  end

  defp normalize_peer_supported_event_types(_event_types), do: []

  defp normalize_peer_limits(limits) when is_map(limits) do
    [
      "max_batch_events",
      "max_ephemeral_items",
      "max_snapshot_channels",
      "max_snapshot_messages",
      "max_snapshot_governance_entries",
      "max_stream_replay_limit",
      "max_session_inflight_batches",
      "max_session_inflight_events",
      "typing_ttl_ms",
      "presence_ttl_ms"
    ]
    |> Enum.reduce(%{}, fn key, acc ->
      case capability_value_from(limits, key) do
        value when is_integer(value) and value > 0 -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp normalize_peer_limits(_limits), do: %{}

  defp normalize_peer_transport_profiles(profiles) when is_map(profiles) do
    preferred_order =
      profiles
      |> value_from(:preferred_order, [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    fallback_order =
      profiles
      |> value_from(:fallback_order, [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    %{}
    |> maybe_put_peer_capability(
      "preferred_order",
      if(preferred_order == [], do: nil, else: preferred_order)
    )
    |> maybe_put_peer_capability(
      "fallback_order",
      if(fallback_order == [], do: nil, else: fallback_order)
    )
    |> maybe_put_peer_capability(
      "session_websocket",
      case value_from(profiles, :session_websocket) do
        %{} = session_profile -> normalize_peer_capability_document(session_profile)
        _ -> nil
      end
    )
  end

  defp normalize_peer_transport_profiles(_profiles), do: %{}

  defp maybe_put_peer_capability(map, _key, nil), do: map
  defp maybe_put_peer_capability(map, _key, []), do: map
  defp maybe_put_peer_capability(map, _key, %{} = value) when map_size(value) == 0, do: map

  defp maybe_put_peer_capability(map, key, value) when is_map(map) and is_binary(key) do
    Map.put(map, key, value)
  end

  defp normalize_peer_capability_document(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested_value}, acc ->
      normalized_key =
        case key do
          binary when is_binary(binary) -> binary
          atom when is_atom(atom) -> Atom.to_string(atom)
          other -> to_string(other)
        end

      Map.put(acc, normalized_key, normalize_peer_capability_document(nested_value))
    end)
  end

  defp normalize_peer_capability_document(value) when is_list(value) do
    Enum.map(value, &normalize_peer_capability_document/1)
  end

  defp normalize_peer_capability_document(value), do: value

  defp normalize_peer_keys(keys, shared_secret) when is_list(keys) do
    normalized = keys |> Enum.map(&normalize_single_peer_key/1) |> Enum.reject(&is_nil/1)

    if Enum.empty?(normalized) and is_binary(shared_secret) do
      {public_key, private_key} = ArblargSDK.derive_keypair_from_secret(shared_secret)

      [
        %{
          id: "k1",
          secret: shared_secret,
          public_key: public_key,
          private_key: private_key,
          active_outbound: true
        }
      ]
    else
      normalized
    end
  end

  defp normalize_peer_keys(_, shared_secret) when is_binary(shared_secret) do
    {public_key, private_key} = ArblargSDK.derive_keypair_from_secret(shared_secret)

    [
      %{
        id: "k1",
        secret: shared_secret,
        public_key: public_key,
        private_key: private_key,
        active_outbound: true
      }
    ]
  end

  defp normalize_peer_keys(_, _), do: []

  defp normalize_single_peer_key(key) when is_list(key) do
    normalize_single_peer_key(Map.new(key))
  end

  defp normalize_single_peer_key(key) when is_map(key) do
    id = normalize_optional_string(value_from(key, :id))
    secret = normalize_optional_string(value_from(key, :secret))
    public_key = decode_key_material(value_from(key, :public_key))
    private_key = decode_key_material(value_from(key, :private_key))

    cond do
      !is_binary(id) ->
        nil

      is_binary(secret) ->
        {derived_public, derived_private} = ArblargSDK.derive_keypair_from_secret(secret)

        %{
          id: id,
          secret: secret,
          public_key: derived_public,
          private_key: derived_private,
          active_outbound: value_from(key, :active_outbound, false) == true
        }

      public_key == :error and private_key == :error ->
        nil

      true ->
        public_key =
          case public_key do
            {:ok, decoded_public} ->
              decoded_public

            :error ->
              case private_key do
                {:ok, decoded_private} ->
                  {derived_public, _} = :crypto.generate_key(:eddsa, :ed25519, decoded_private)
                  derived_public

                :error ->
                  nil
              end
          end

        private_key = if match?({:ok, _}, private_key), do: elem(private_key, 1), else: nil

        %{
          id: id,
          secret: nil,
          public_key: public_key,
          private_key: private_key,
          active_outbound: value_from(key, :active_outbound, false) == true
        }
    end
  end

  defp normalize_single_peer_key(_), do: nil

  defp resolve_active_outbound_key_id(peer, keys) do
    configured = normalize_optional_string(value_from(peer, :active_outbound_key_id))

    cond do
      is_binary(configured) and
          Enum.any?(keys, &(&1.id == configured and is_binary(&1.private_key))) ->
        configured

      key = Enum.find(keys, &(&1.active_outbound and is_binary(&1.private_key))) ->
        key.id

      key = Enum.find(keys, &is_binary(&1.private_key)) ->
        key.id

      true ->
        keys |> List.first() |> Map.get(:id)
    end
  end

  defp decode_key_material(value) when is_binary(value) and byte_size(value) == 32,
    do: {:ok, value}

  defp decode_key_material(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      :error
    else
      case Base.url_decode64(trimmed, padding: false) do
        {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
        _ -> decode_key_material_standard_base64(trimmed)
      end
    end
  end

  defp decode_key_material(_), do: :error

  defp decode_key_material_standard_base64(value) do
    case Base.decode64(value) do
      {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
      _ -> :error
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      nil
    else
      trimmed
    end
  end

  defp normalize_optional_string(_), do: nil

  defp valid_session_websocket_url?(url, allow_insecure_transport)
       when is_binary(url) and is_boolean(allow_insecure_transport) do
    case URI.parse(url) do
      %URI{scheme: "wss", host: host} when is_binary(host) and host != "" ->
        true

      %URI{scheme: "ws", host: host}
      when is_binary(host) and host != "" and allow_insecure_transport ->
        true

      _ ->
        false
    end
  end

  defp valid_session_websocket_url?(_url, _allow_insecure_transport), do: false

  defp websocket_base_url(base_url, allow_insecure_transport)
       when is_binary(base_url) and is_boolean(allow_insecure_transport) do
    case URI.parse(base_url) do
      %URI{scheme: "https"} = uri ->
        %{uri | scheme: "wss"} |> URI.to_string() |> String.trim_trailing("/")

      %URI{scheme: "http"} = uri when allow_insecure_transport ->
        %{uri | scheme: "ws"} |> URI.to_string() |> String.trim_trailing("/")

      _ ->
        nil
    end
  end

  defp value_from(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp capability_value_from(map, key, default \\ nil) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil ->
        map
        |> Enum.find(fn
          {atom_key, _value} when is_atom(atom_key) -> Atom.to_string(atom_key) == key
          _ -> false
        end)
        |> case do
          {_, value} -> value
          nil -> default
        end

      value ->
        value
    end
  end
end
