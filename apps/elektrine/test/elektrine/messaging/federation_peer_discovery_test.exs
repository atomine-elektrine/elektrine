defmodule Elektrine.Messaging.FederationPeerDiscoveryTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.Messaging.{
    ArblargProfiles,
    ArblargSDK,
    Federation,
    Federation.Transport,
    FederationDiscoveredPeer
  }

  alias Elektrine.Repo

  describe "dynamic peer discovery" do
    test "discovers and caches unknown peers from discovery metadata" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.open.example", "open.example" ->
              [
                authenticated_dns_identity_proof(
                  dynamic_discovery_document("open.example", "open-example-secret")
                )
              ]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "open.example", _urls ->
              {:ok, dynamic_discovery_document("open.example", "open-example-secret")}

            _domain, _urls ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:ok, peer} = Federation.discover_peer("open.example")
      assert peer.domain == "open.example"
      assert peer.allow_incoming == true
      assert peer.allow_outgoing == true

      assert %FederationDiscoveredPeer{} =
               Repo.get_by(FederationDiscoveredPeer, domain: "open.example")

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          discovery_fetcher: fn _domain, _urls -> {:error, :should_not_refetch} end
        )
      )

      assert %{} = Federation.outgoing_peer("open.example")
      assert %{} = Federation.incoming_peer("open.example")
    end

    test "rejects discovery documents without a claimed domain" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      discovery_document =
        dynamic_discovery_document("open.example", "open-example-secret", claimed_domain: nil)

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.open.example", "open.example" ->
              [authenticated_dns_identity_proof(discovery_document)]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "open.example", _urls ->
              {:ok, discovery_document}

            _domain, _urls ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:error, :invalid_discovery_domain} = Federation.discover_peer("open.example")
    end

    test "rejects discovery documents with unsupported default protocol versions" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      discovery_document =
        dynamic_discovery_document("open.example", "open-example-secret",
          default_protocol_version: "9.9"
        )

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.open.example", "open.example" ->
              [authenticated_dns_identity_proof(discovery_document)]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "open.example", _urls ->
              {:ok, discovery_document}

            _domain, _urls ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:error, :unsupported_version} = Federation.discover_peer("open.example")
    end

    test "rejects plaintext websocket session endpoints in normal operation" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      discovery_document =
        dynamic_discovery_document("open.example", "open-example-secret",
          session_websocket: "ws://open.example/_arblarg/session"
        )

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.open.example", "open.example" ->
              [authenticated_dns_identity_proof(discovery_document)]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "open.example", _urls ->
              {:ok, discovery_document}

            _domain, _urls ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:error, :invalid_discovery_endpoints} = Federation.discover_peer("open.example")
    end

    test "peer controls surface discovered peer metadata" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.open.example", "open.example" ->
              [
                authenticated_dns_identity_proof(
                  dynamic_discovery_document("open.example", "open-example-secret")
                )
              ]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "open.example", _urls ->
              {:ok, dynamic_discovery_document("open.example", "open-example-secret")}

            _domain, _urls ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:ok, _peer} = Federation.discover_peer("open.example")

      assert control =
               Enum.find(Federation.list_peer_controls(), fn control ->
                 control.domain == "open.example"
               end)

      assert control.discovered == true
      assert control.configured == false
      assert control.trust_state == "trusted"
      assert control.protocol_version == "1.0"
      assert control.effective_allow_incoming == true
      assert control.effective_allow_outgoing == true
      assert is_map(control.features)
      assert control.last_discovered_at
    end

    test "replaced discovery identities are quarantined until operator override" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      discovery_versions = :ets.new(:arblarg_discovery_versions, [:set, :public])
      :ets.insert(discovery_versions, {:secret, "first-secret"})

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.swap.example", "swap.example" ->
              [{:secret, secret}] = :ets.lookup(discovery_versions, :secret)

              [
                authenticated_dns_identity_proof(
                  dynamic_discovery_document("swap.example", secret)
                )
              ]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "swap.example", _urls ->
              [{:secret, secret}] = :ets.lookup(discovery_versions, :secret)
              {:ok, dynamic_discovery_document("swap.example", secret)}

            _domain, _urls ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        if :ets.info(discovery_versions) != :undefined do
          :ets.delete(discovery_versions)
        end

        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:ok, peer} = Federation.discover_peer("swap.example")
      assert peer.trust_state == "trusted"
      assert %{} = Federation.outgoing_peer("swap.example")

      :ets.insert(discovery_versions, {:secret, "second-secret"})

      assert {:ok, peer} = Federation.refresh_peer_discovery("swap.example")
      assert peer.trust_state == "replaced"
      assert peer.allow_incoming == false
      assert peer.allow_outgoing == false
      assert is_nil(Federation.incoming_peer("swap.example"))
      assert is_nil(Federation.outgoing_peer("swap.example"))

      assert control =
               Enum.find(Federation.list_peer_controls(), fn control ->
                 control.domain == "swap.example"
               end)

      assert control.requires_operator_action == true
      assert control.blocked == true
      assert control.trust_state == "replaced"

      assert {:ok, _policy} =
               Federation.upsert_peer_policy("swap.example", %{
                 blocked: false,
                 allow_incoming: true,
                 allow_outgoing: true
               })

      assert %{} = Federation.incoming_peer("swap.example")
      assert %{} = Federation.outgoing_peer("swap.example")
    end

    test "merges extension support advertised only through the profiles document" do
      previous = Application.get_env(:elektrine, :messaging_federation, [])
      role_event_type = hd(ArblargSDK.roles_event_types())

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [],
          dns_identity_fetcher: fn
            "_arblarg.profiles-only.example", "profiles-only.example" ->
              [
                authenticated_dns_identity_proof(
                  dynamic_discovery_document("profiles-only.example", "profiles-only-secret")
                )
              ]

            _name, _domain ->
              []
          end,
          discovery_fetcher: fn
            "profiles-only.example", _urls ->
              {:ok, dynamic_discovery_document("profiles-only.example", "profiles-only-secret")}

            _domain, _urls ->
              {:error, :not_found}
          end,
          profiles_fetcher: fn
            "profiles-only.example", _url ->
              {:ok, dynamic_profiles_document(role_event_type)}

            _domain, _url ->
              {:error, :not_found}
          end
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      assert {:ok, peer} = Federation.discover_peer("profiles-only.example")
      assert Transport.peer_supports_event_type?(peer, role_event_type)

      assert ArblargProfiles.community_profile_id() in get_in(peer.features, [
               "compatibility_claims"
             ])
    end
  end

  describe "extension negotiation" do
    setup do
      previous = Application.get_env(:elektrine, :messaging_federation, [])

      Application.put_env(
        :elektrine,
        :messaging_federation,
        Keyword.merge(previous,
          enabled: true,
          peers: [
            %{
              domain: "bootstrap.example",
              base_url: "https://bootstrap.example",
              shared_secret: "bootstrap-secret",
              allow_incoming: true,
              allow_outgoing: true,
              supported_event_types: ["server.upsert"]
            },
            %{
              domain: "core-only.example",
              base_url: "https://core-only.example",
              shared_secret: "core-only-secret",
              allow_incoming: true,
              allow_outgoing: true,
              supported_event_types: ArblargSDK.core_event_types()
            }
          ]
        )
      )

      on_exit(fn ->
        Application.put_env(:elektrine, :messaging_federation, previous)
      end)

      :ok
    end

    test "filters bootstrap extension fanout to peers that advertise support" do
      bootstrap_event_type = ArblargSDK.bootstrap_server_upsert_event_type()

      bootstrap_peer = %{
        domain: "bootstrap.example",
        supported_event_types: [bootstrap_event_type],
        features: %{"supported_event_types" => [bootstrap_event_type]}
      }

      core_only_peer = %{
        domain: "core-only.example",
        supported_event_types: ArblargSDK.core_event_types(),
        features: %{"supported_event_types" => ArblargSDK.core_event_types()}
      }

      assert Transport.peer_supports_event_type?(bootstrap_peer, bootstrap_event_type)
      refute Transport.peer_supports_event_type?(core_only_peer, bootstrap_event_type)
    end

    test "accepts community profile claims as extension support" do
      peer = %{
        features: %{
          "compatibility_claims" => [ArblargProfiles.community_profile_id()]
        }
      }

      assert Transport.peer_supports_event_type?(peer, hd(ArblargSDK.roles_event_types()))
      refute Transport.peer_supports_event_type?(%{}, hd(ArblargSDK.roles_event_types()))
    end
  end

  defp dynamic_discovery_document(domain, secret, opts \\ []) do
    {public_key, _private_key} = ArblargSDK.derive_keypair_from_secret(secret)
    base_url = "https://#{domain}"
    claimed_domain = Keyword.get(opts, :claimed_domain, domain)

    default_protocol_version =
      Keyword.get(opts, :default_protocol_version, ArblargSDK.protocol_version())

    session_websocket =
      Keyword.get(opts, :session_websocket, "wss://#{domain}/_arblarg/session")

    unsigned =
      %{
        "protocol" => ArblargSDK.protocol_name(),
        "protocol_id" => ArblargSDK.protocol_id(),
        "protocol_labels" => [ArblargSDK.protocol_label()],
        "default_protocol_label" => ArblargSDK.protocol_label(),
        "default_protocol_version" => default_protocol_version,
        "version" => 1,
        "identity" => %{
          "algorithm" => "ed25519",
          "current_key_id" => "k1",
          "keys" => [
            %{
              "id" => "k1",
              "algorithm" => "ed25519",
              "public_key" => Base.url_encode64(public_key, padding: false)
            }
          ]
        },
        "endpoints" => %{
          "well_known" => "#{base_url}/.well-known/_arblarg",
          "events" => "#{base_url}/_arblarg/events",
          "events_batch" => "#{base_url}/_arblarg/events/batch",
          "ephemeral" => "#{base_url}/_arblarg/ephemeral",
          "sync" => "#{base_url}/_arblarg/sync",
          "stream_events" => "#{base_url}/_arblarg/streams/events",
          "session_websocket" => session_websocket,
          "snapshot_template" => "#{base_url}/_arblarg/servers/{server_id}/snapshot",
          "public_servers" => "#{base_url}/_arblarg/servers/public",
          "profiles" => "#{base_url}/_arblarg/profiles",
          "schema_template" => "#{base_url}/_arblarg/{version}/schemas/{name}"
        }
      }
      |> maybe_put_field("domain", claimed_domain)

    Map.put(unsigned, "signature", %{
      "algorithm" => "ed25519",
      "key_id" => "k1",
      "value" =>
        unsigned
        |> ArblargSDK.canonical_json_payload()
        |> ArblargSDK.sign_payload(secret)
    })
  end

  defp dynamic_profiles_document(event_type) when is_binary(event_type) do
    %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "default_protocol_version" => ArblargSDK.protocol_version(),
      "version" => 1,
      "compatibility_claims" => [ArblargProfiles.community_profile_id()],
      "events" => %{"supported" => [event_type]},
      "extensions" => [
        %{
          "urn" => ArblargProfiles.extension_urn_for_event_type(event_type)
        }
      ]
    }
  end

  defp maybe_put_field(map, _key, nil), do: map

  defp maybe_put_field(map, key, value) when is_map(map) and is_binary(key) do
    Map.put(map, key, value)
  end

  defp discovery_fingerprint(%{
         "identity" => %{"current_key_id" => current_key_id, "keys" => keys}
       })
       when is_list(keys) do
    normalized =
      keys
      |> Enum.map(fn key ->
        %{
          "id" => key["id"],
          "public_key" => key["public_key"]
        }
      end)
      |> Enum.sort_by(&{&1["id"] || "", &1["public_key"] || ""})

    :crypto.hash(
      :sha256,
      Jason.encode!(%{"current_key_id" => current_key_id, "keys" => normalized})
    )
    |> Base.url_encode64(padding: false)
  end

  defp authenticated_dns_identity_proof(discovery_document) do
    %{
      text: "fingerprint=#{discovery_fingerprint(discovery_document)}",
      authenticated: true
    }
  end
end
