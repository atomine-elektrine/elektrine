defmodule Elektrine.Messaging.Federation.Runtime do
  @moduledoc false

  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Messaging.Federation.Config
  alias Elektrine.RuntimeEnv

  @clock_skew_seconds ArblargSDK.clock_skew_seconds()

  def federation_config do
    Application.get_env(:elektrine, :messaging_federation, [])
  end

  def enabled? do
    federation_config() |> Keyword.get(:enabled, false)
  end

  def local_domain do
    configured =
      federation_config()
      |> Keyword.get(:local_domain)
      |> normalize_optional_string()
      |> case do
        nil -> nil
        value -> String.downcase(value)
      end

    configured ||
      System.get_env("INSTANCE_DOMAIN")
      |> normalize_optional_string()
      |> case do
        nil -> Elektrine.Domains.instance_domain()
        domain -> String.downcase(domain)
      end
  end

  def local_base_url do
    Config.local_base_url(federation_config(), local_domain())
  end

  def local_identity_key_id do
    Config.local_identity_key_id(federation_config())
  end

  def local_identity_discovery_identity do
    Config.local_identity_discovery_identity(local_identity_keys(), local_identity_key_id())
  end

  def local_identity_keys do
    Config.local_identity_keys(
      federation_config(),
      local_identity_key_id(),
      local_domain(),
      enabled?(),
      prod_environment?()
    )
  end

  def local_event_signing_material do
    key_id = local_identity_key_id()

    case local_identity_keys() |> Enum.find(&(&1.id == key_id and is_binary(&1.private_key))) do
      %{id: id, private_key: private_key} ->
        {id, private_key}

      _ ->
        case local_identity_keys() |> Enum.find(&is_binary(&1.private_key)) do
          %{id: id, private_key: private_key} ->
            {id, private_key}

          _ ->
            derived_key_seed_source =
              federation_config()
              |> Keyword.get(
                :identity_shared_secret,
                "#{local_domain()}:#{key_id}"
              )

            {_public_key, private_key} =
              ArblargSDK.derive_keypair_from_secret(derived_key_seed_source)

            {key_id, private_key}
        end
    end
  end

  def configured_peers do
    Config.configured_peers(federation_config(), allow_insecure_transport?())
  end

  def official_relay_operator do
    Config.official_relay_operator(federation_config())
  end

  def discovery_official_relays do
    Config.discovery_official_relays(federation_config())
  end

  def outbound_events_batch_url(peer) do
    Config.outbound_events_batch_url(peer)
  end

  def outbound_events_url(peer) do
    Config.outbound_events_url(peer)
  end

  def outbound_ephemeral_url(peer) do
    Config.outbound_ephemeral_url(peer)
  end

  def outbound_sync_url(peer) do
    Config.outbound_sync_url(peer)
  end

  def outbound_stream_events_url(peer, query_string) do
    Config.outbound_stream_events_url(peer, query_string)
  end

  def outbound_session_websocket_url(peer) do
    Config.outbound_session_websocket_url(peer)
  end

  def outbound_snapshot_url(peer, remote_server_id) do
    Config.outbound_snapshot_url(peer, remote_server_id)
  end

  def delivery_timeout_ms do
    Config.delivery_timeout_ms(federation_config())
  end

  def outbox_max_attempts do
    Config.outbox_max_attempts(federation_config())
  end

  def delivery_batch_size do
    Config.delivery_batch_size(federation_config())
  end

  def outbox_backoff_seconds(attempt_count) do
    Config.outbox_backoff_seconds(federation_config(), attempt_count)
  end

  def outbox_partition_month(%DateTime{} = datetime) do
    Config.outbox_partition_month(datetime)
  end

  def delivery_concurrency do
    Config.delivery_concurrency(federation_config())
  end

  def replay_nonce_ttl_seconds do
    Config.replay_nonce_ttl_seconds(federation_config(), @clock_skew_seconds)
  end

  def stream_replay_limit do
    Config.stream_replay_limit(federation_config())
  end

  def incoming_batch_limit do
    Config.incoming_batch_limit(federation_config())
  end

  def incoming_ephemeral_limit do
    Config.incoming_ephemeral_limit(federation_config())
  end

  def snapshot_channel_limit do
    Config.snapshot_channel_limit(federation_config())
  end

  def snapshot_message_limit do
    Config.snapshot_message_limit(federation_config())
  end

  def snapshot_governance_limit do
    Config.snapshot_governance_limit(federation_config())
  end

  def discovery_ttl_seconds do
    Config.discovery_ttl_seconds(federation_config())
  end

  def discovery_stale_grace_seconds do
    Config.discovery_stale_grace_seconds(federation_config())
  end

  def session_max_inflight_batches do
    Config.session_max_inflight_batches(federation_config())
  end

  def session_max_inflight_events do
    Config.session_max_inflight_events(federation_config())
  end

  def presence_ttl_seconds do
    Config.presence_ttl_seconds(federation_config())
  end

  def allow_insecure_transport? do
    Config.allow_insecure_transport?(federation_config())
  end

  def clock_skew_seconds do
    Config.clock_skew_seconds(federation_config(), @clock_skew_seconds)
  end

  def prod_environment? do
    RuntimeEnv.prod?()
  end

  defp normalize_optional_string(value) when is_binary(value),
    do: Elektrine.Strings.present(value)

  defp normalize_optional_string(_value), do: nil
end
