defmodule Elektrine.Messaging.Federation.PublicDiscovery do
  @moduledoc false

  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Messaging.Federation.{Contexts, Discovery, Peers, Protocol, Runtime, Utils}

  def discover_peer(domain, opts \\ [])

  def discover_peer(domain, opts) when is_binary(domain) and is_list(opts) do
    Discovery.discover_peer(domain, opts, discovery_context())
  end

  def discover_peer(_domain, _opts), do: {:error, :invalid_domain}

  def refresh_peer_discovery(domain) when is_binary(domain) do
    Discovery.discover_peer(domain, [force: true], discovery_context())
  end

  def refresh_peer_discovery(_domain), do: {:error, :invalid_domain}

  def local_discovery_document(version \\ ArblargSDK.protocol_version()) do
    Protocol.local_discovery_document(version, protocol_context())
  end

  def arblarg_profiles_document(version \\ ArblargSDK.protocol_version()) do
    Protocol.arblarg_profiles_document(version, protocol_context())
  end

  def discovery_limits_for_transport do
    Protocol.discovery_limits_for_transport(protocol_context())
  end

  def transport_profiles_for_transport do
    Protocol.transport_profiles_for_transport(protocol_context())
  end

  def session_flow_control_for_transport do
    Protocol.session_flow_control_for_transport(protocol_context())
  end

  def transport_profiles_document do
    Protocol.transport_profiles_document(discovery_limits(), Runtime.discovery_ttl_seconds())
  end

  defp discovery_limits do
    %{
      "max_batch_events" => Runtime.incoming_batch_limit(),
      "max_ephemeral_items" => Runtime.incoming_ephemeral_limit(),
      "max_snapshot_channels" => Runtime.snapshot_channel_limit(),
      "max_snapshot_messages" => Runtime.snapshot_message_limit(),
      "max_snapshot_governance_entries" => Runtime.snapshot_governance_limit(),
      "max_stream_replay_limit" => Runtime.stream_replay_limit(),
      "max_session_inflight_batches" => Runtime.session_max_inflight_batches(),
      "max_session_inflight_events" => Runtime.session_max_inflight_events(),
      "typing_ttl_ms" => 10_000,
      "presence_ttl_ms" => 86_400_000
    }
  end

  defp protocol_context do
    %{
      local_domain: Runtime.local_domain(),
      identity: Runtime.local_identity_discovery_identity(),
      base_url: Runtime.local_base_url(),
      allow_insecure_transport: Runtime.allow_insecure_transport?(),
      limits: discovery_limits(),
      cache_ttl_seconds: Runtime.discovery_ttl_seconds(),
      official_relay_operator: Runtime.official_relay_operator(),
      official_relays: Runtime.discovery_official_relays(),
      clock_skew_seconds: Runtime.clock_skew_seconds(),
      sign_fun: &sign_discovery_document/1
    }
  end

  defp discovery_context do
    Contexts.discovery(%{
      peers: &Peers.peers/0,
      truncate: &Utils.truncate/1
    })
  end

  defp sign_discovery_document(document) do
    Discovery.sign_discovery_document(document, discovery_context())
  end
end
