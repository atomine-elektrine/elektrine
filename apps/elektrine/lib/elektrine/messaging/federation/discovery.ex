defmodule Elektrine.Messaging.Federation.Discovery do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.HTTP.Backoff

  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Messaging.FederationDiscoveredPeer

  alias Elektrine.Messaging.Federation.Config
  alias Elektrine.Messaging.Federation.PeerPolicies

  alias Elektrine.Repo
  alias Elektrine.Security.URLValidator

  @max_discovery_body_bytes 262_144

  def discover_peer(domain, opts, context)
      when is_binary(domain) and is_list(opts) and is_map(context) do
    force? = Keyword.get(opts, :force, false)

    case normalize_peer_domain(domain) do
      {:ok, normalized_domain} ->
        cond do
          normalized_domain == call(context, :local_domain, []) ->
            {:error, :local_domain}

          peer = maybe_resolve_configured_peer(normalized_domain, context) ->
            {:ok, peer}

          peer = cached_discovered_peer(normalized_domain, force?, context) ->
            {:ok, peer}

          true ->
            fetch_and_cache_peer(normalized_domain, context)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def discover_peer(_domain, _opts, _context), do: {:error, :invalid_domain}

  def resolve_peer(domain, context) when is_binary(domain) and is_map(context) do
    with {:ok, normalized_domain} <- normalize_peer_domain(domain),
         false <- normalized_domain == call(context, :local_domain, []) do
      maybe_resolve_configured_peer(normalized_domain, context) ||
        resolve_discovered_peer(normalized_domain, context)
    else
      _ -> nil
    end
  end

  def resolve_peer(_domain, _context), do: nil

  def discovered_peer_controls(context) when is_map(context) do
    list_discovered_peer_controls(context)
  rescue
    _ ->
      []
  end

  def list_discovered_peer_controls(context, opts \\ []) when is_map(context) and is_list(opts) do
    query =
      FederationDiscoveredPeer
      |> order_by([peer], asc: peer.domain)
      |> maybe_filter_discovered_domains(Keyword.get(opts, :domains))
      |> maybe_filter_discovered_search(Keyword.get(opts, :search))

    Repo.all(query)
    |> Enum.map(&build_discovered_peer_control(&1, context))
  end

  def list_discovered_peer_domains(search_query \\ nil) do
    FederationDiscoveredPeer
    |> maybe_filter_discovered_search(search_query)
    |> select([peer], peer.domain)
    |> order_by([peer], asc: peer.domain)
    |> Repo.all()
  rescue
    _ ->
      []
  end

  def discovered_peer_state_map(search_query \\ nil) do
    FederationDiscoveredPeer
    |> maybe_filter_discovered_search(search_query)
    |> select([peer], %{
      domain: peer.domain,
      trust_state: peer.trust_state
    })
    |> Repo.all()
    |> Map.new(fn peer ->
      allow? = peer.trust_state != "replaced"

      {peer.domain,
       %{
         blocked: peer.trust_state == "replaced",
         effective_allow_incoming: allow?,
         effective_allow_outgoing: allow?
       }}
    end)
  rescue
    _ ->
      %{}
  end

  def sign_discovery_document(document, context) when is_map(document) and is_map(context) do
    {key_id, signing_material} = call(context, :local_event_signing_material, [])

    Map.put(document, "signature", %{
      "algorithm" => ArblargSDK.signature_algorithm(),
      "key_id" => key_id,
      "value" =>
        document
        |> discovery_signature_payload()
        |> ArblargSDK.sign_payload(signing_material)
    })
  end

  def sign_discovery_document(document, _context), do: document

  def discovery_signature_payload(document) when is_map(document) do
    document
    |> Map.delete("signature")
    |> ArblargSDK.canonical_json_payload()
  end

  def discovery_signature_payload(_document), do: ""

  def normalize_peer_domain(domain) when is_binary(domain) do
    normalized =
      domain
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/^https?:\/\//, "")
      |> String.split("/", parts: 2)
      |> List.first()
      |> to_string()
      |> String.trim(".")

    if normalized == "" do
      {:error, :invalid_domain}
    else
      {:ok, normalized}
    end
  end

  def normalize_peer_domain(_domain), do: {:error, :invalid_domain}

  defp maybe_resolve_configured_peer(domain, context) when is_binary(domain) do
    Enum.find(call(context, :peers, []), fn peer ->
      String.downcase(peer.domain) == domain
    end)
  end

  defp maybe_resolve_configured_peer(_domain, _context), do: nil

  defp cached_discovered_peer(_domain, true, _context), do: nil

  defp cached_discovered_peer(domain, false, context) when is_binary(domain) do
    case get_discovered_peer_record(domain) do
      %FederationDiscoveredPeer{} = record ->
        cond do
          not discovered_peer_stale?(record, context) ->
            build_discovered_peer(record, context)

          discovered_peer_within_grace?(record, context) ->
            build_discovered_peer(record, context)

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp cached_discovered_peer(_domain, _force?, _context), do: nil

  defp resolve_discovered_peer(domain, context) when is_binary(domain) and is_map(context) do
    case get_discovered_peer_record(domain) do
      nil ->
        case fetch_and_cache_peer(domain, context) do
          {:ok, %{} = peer} -> peer
          _ -> nil
        end

      %FederationDiscoveredPeer{} = record ->
        if discovered_peer_stale?(record, context) do
          case fetch_and_cache_peer(domain, context) do
            {:ok, %{} = peer} ->
              peer

            {:error, reason} ->
              _ = record_discovery_failure(domain, reason)

              if discovered_peer_within_grace?(record, context) do
                build_discovered_peer(record, context)
              else
                nil
              end
          end
        else
          build_discovered_peer(record, context)
        end
    end
  end

  defp resolve_discovered_peer(_domain, _context), do: nil

  defp fetch_and_cache_peer(domain, context) when is_binary(domain) and is_map(context) do
    with {:ok, attrs} <- fetch_remote_discovery_document(domain, context),
         {:ok, record} <- upsert_discovered_peer(attrs),
         %{} = peer <- build_discovered_peer(record, context) do
      {:ok, peer}
    else
      nil ->
        _ = record_discovery_failure(domain, :invalid_discovered_peer)
        {:error, :invalid_discovered_peer}

      {:error, reason} ->
        _ = record_discovery_failure(domain, reason)
        {:error, reason}

      _ ->
        _ = record_discovery_failure(domain, :invalid_discovered_peer)
        {:error, :invalid_discovered_peer}
    end
  end

  defp fetch_and_cache_peer(_domain, _context), do: {:error, :invalid_domain}

  defp fetch_remote_discovery_document(domain, context)
       when is_binary(domain) and is_map(context) do
    urls = discovery_candidate_urls(domain, context)

    case call(context, :federation_config, []) |> Keyword.get(:discovery_fetcher) do
      fun when is_function(fun, 2) ->
        case fun.(domain, urls) do
          {:ok, payload, discovery_url} ->
            normalize_discovery_document(
              domain,
              payload,
              discovery_url || List.first(urls),
              false,
              context
            )

          {:ok, payload} ->
            normalize_discovery_document(domain, payload, List.first(urls), false, context)

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:invalid_discovery_fetcher_response, other}}
        end

      _ ->
        fetch_remote_discovery_document_over_http(domain, urls, context)
    end
  end

  defp fetch_remote_discovery_document(_domain, _context), do: {:error, :invalid_domain}

  defp fetch_remote_discovery_document_over_http(_domain, [], _context),
    do: {:error, :discovery_unavailable}

  defp fetch_remote_discovery_document_over_http(domain, urls, context)
       when is_list(urls) and is_map(context) do
    Enum.reduce_while(urls, {:error, :discovery_unavailable}, fn url, _acc ->
      case fetch_single_discovery_url(url, context) do
        {:ok, payload} ->
          case normalize_discovery_document(domain, payload, url, true, context) do
            {:ok, attrs} -> {:halt, {:ok, attrs}}
            {:error, reason} -> {:cont, {:error, reason}}
          end

        {:error, reason} ->
          {:cont, {:error, reason}}
      end
    end)
  end

  defp fetch_single_discovery_url(url, context) when is_binary(url) and is_map(context) do
    headers = [{"accept", "application/json"}]

    case validate_discovery_url(url, context) do
      :ok ->
        case Backoff.get(url, headers,
               timeout: call(context, :delivery_timeout_ms, []),
               recv_timeout: call(context, :delivery_timeout_ms, [])
             ) do
          {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
            cond do
              !is_binary(body) ->
                {:error, :invalid_discovery_response}

              byte_size(body) > @max_discovery_body_bytes ->
                {:error, :discovery_response_too_large}

              true ->
                case Jason.decode(body) do
                  {:ok, payload} -> {:ok, payload}
                  {:error, reason} -> {:error, {:invalid_json, reason}}
                end
            end

          {:ok, %Finch.Response{status: status}} when status in [404, 406, 410] ->
            {:error, {:http_error, status}}

          {:ok, %Finch.Response{status: status, body: body}} ->
            {:error, {:http_error, status, call(context, :truncate, [body])}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_single_discovery_url(_url, _context), do: {:error, :invalid_discovery_url}

  defp normalize_discovery_document(domain, payload, discovery_url, validate_urls?, context)
       when is_binary(domain) and is_map(payload) and is_map(context) do
    protocol = normalize_optional_string(discovery_field(payload, "protocol"))
    protocol_id = normalize_optional_string(discovery_field(payload, "protocol_id"))

    with true <-
           protocol_id == ArblargSDK.protocol_id() and protocol == ArblargSDK.protocol_name(),
         {:ok, claimed_domain} <- normalize_discovery_claimed_domain(domain, payload),
         {:ok, protocol_version} <- normalize_discovery_protocol_version(payload),
         %{} = identity <- normalize_discovery_identity(discovery_field(payload, "identity")),
         :ok <- verify_discovery_document_signature(payload, identity),
         identity_fingerprint when is_binary(identity_fingerprint) <-
           discovery_identity_fingerprint(identity),
         :ok <-
           verify_discovery_bootstrap_trust(
             claimed_domain,
             identity,
             identity_fingerprint,
             context
           ),
         raw_endpoints when is_map(raw_endpoints) <- discovery_field(payload, "endpoints"),
         {:ok, endpoints} <-
           normalize_discovery_endpoints(raw_endpoints, claimed_domain, validate_urls?, context),
         true <- map_size(endpoints) > 0 or {:error, :invalid_discovery_endpoints},
         base_url when is_binary(base_url) <-
           extract_discovery_base_url(
             endpoints,
             discovery_url,
             claimed_domain,
             validate_urls?,
             context
           ) do
      {:ok,
       %{
         domain: claimed_domain,
         base_url: base_url,
         discovery_url:
           normalize_discovery_url(
             discovery_url,
             validate_urls?,
             claimed_domain,
             ["http", "https"],
             context
           ) ||
             discovery_url,
         protocol: ArblargSDK.protocol_name(),
         protocol_id: protocol_id || ArblargSDK.protocol_id(),
         protocol_version: protocol_version,
         trust_state: "trusted",
         identity_fingerprint: identity_fingerprint,
         previous_identity_fingerprint: nil,
         last_key_change_at: nil,
         identity: identity,
         endpoints: endpoints,
         features: normalize_discovery_capabilities(payload),
         last_discovered_at: DateTime.utc_now() |> DateTime.truncate(:second),
         last_error: nil
       }}
    else
      false -> {:error, :unsupported_protocol}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :missing_base_url}
      _ -> {:error, :invalid_discovery_document}
    end
  end

  defp normalize_discovery_document(_domain, _payload, _discovery_url, _validate_urls?, _context) do
    {:error, :invalid_discovery_document}
  end

  defp normalize_discovery_signature(signature) when is_map(signature) do
    algorithm = normalize_optional_string(discovery_field(signature, "algorithm"))
    key_id = normalize_optional_string(discovery_field(signature, "key_id"))
    value = normalize_optional_string(discovery_field(signature, "value"))

    cond do
      algorithm != ArblargSDK.signature_algorithm() -> nil
      !is_binary(key_id) -> nil
      !is_binary(value) -> nil
      true -> %{"algorithm" => algorithm, "key_id" => key_id, "value" => value}
    end
  end

  defp normalize_discovery_signature(_signature), do: nil

  defp verify_discovery_document_signature(payload, identity)
       when is_map(payload) and is_map(identity) do
    signature =
      payload
      |> discovery_field("signature")
      |> normalize_discovery_signature()

    with %{} = signature <- signature,
         key_id when is_binary(key_id) <- discovery_field(signature, "key_id"),
         keys when is_list(keys) <- discovery_field(identity, "keys"),
         %{} = key <- Enum.find(keys, &(discovery_field(&1, "id") == key_id)),
         public_key when is_binary(public_key) <- discovery_field(key, "public_key"),
         true <-
           ArblargSDK.verify_payload_signature(
             discovery_signature_payload(payload),
             public_key,
             discovery_field(signature, "value")
           ) do
      :ok
    else
      nil -> {:error, :invalid_discovery_signature}
      false -> {:error, :invalid_discovery_signature}
      _ -> {:error, :invalid_discovery_signature}
    end
  end

  defp verify_discovery_document_signature(_payload, _identity),
    do: {:error, :invalid_discovery_signature}

  defp normalize_discovery_claimed_domain(domain, payload)
       when is_binary(domain) and is_map(payload) do
    case normalize_peer_domain(discovery_field(payload, "domain")) do
      {:ok, ^domain} -> {:ok, domain}
      {:ok, _other} -> {:error, :domain_mismatch}
      {:error, _} -> {:error, :invalid_discovery_domain}
    end
  end

  defp normalize_discovery_protocol_version(payload) when is_map(payload) do
    supported_version = ArblargSDK.protocol_version()

    case normalize_optional_string(discovery_field(payload, "default_protocol_version")) do
      ^supported_version ->
        {:ok, supported_version}

      version when is_binary(version) ->
        {:error, :unsupported_version}

      _ ->
        {:error, :invalid_discovery_document}
    end
  end

  defp normalize_discovery_protocol_version(_payload), do: {:error, :invalid_discovery_document}

  defp normalize_discovery_identity(identity) when is_map(identity) do
    keys =
      case discovery_field(identity, "keys") do
        keys when is_list(keys) ->
          keys
          |> Enum.map(&normalize_discovery_key/1)
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end

    current_key_id = normalize_optional_string(discovery_field(identity, "current_key_id"))

    current_key_id =
      if is_binary(current_key_id) and
           Enum.any?(keys, &(discovery_field(&1, "id") == current_key_id)) do
        current_key_id
      else
        keys |> List.first() |> then(&discovery_field(&1, "id"))
      end

    if keys == [] do
      nil
    else
      %{
        "algorithm" => ArblargSDK.signature_algorithm(),
        "current_key_id" => current_key_id,
        "keys" => keys
      }
    end
  end

  defp normalize_discovery_identity(_identity), do: nil

  defp normalize_discovery_key(key) when is_map(key) do
    id = normalize_optional_string(discovery_field(key, "id"))
    algorithm = normalize_optional_string(discovery_field(key, "algorithm"))
    public_key = normalize_optional_string(discovery_field(key, "public_key"))

    cond do
      !is_binary(id) ->
        nil

      !is_binary(public_key) ->
        nil

      is_binary(algorithm) and String.downcase(algorithm) != ArblargSDK.signature_algorithm() ->
        nil

      true ->
        %{"id" => id, "algorithm" => ArblargSDK.signature_algorithm(), "public_key" => public_key}
    end
  end

  defp normalize_discovery_key(_key), do: nil

  defp normalize_discovery_endpoints(endpoints, claimed_domain, validate_urls?, context)
       when is_map(endpoints) and is_binary(claimed_domain) and is_map(context) do
    [
      {"well_known", discovery_field(endpoints, "well_known"), ["http", "https"]},
      {"well_known_versioned", discovery_field(endpoints, "well_known_versioned"),
       ["http", "https"]},
      {"events", discovery_field(endpoints, "events"), ["http", "https"]},
      {"events_batch", discovery_field(endpoints, "events_batch"), ["http", "https"]},
      {"ephemeral", discovery_field(endpoints, "ephemeral"), ["http", "https"]},
      {"sync", discovery_field(endpoints, "sync"), ["http", "https"]},
      {"stream_events", discovery_field(endpoints, "stream_events"), ["http", "https"]},
      {"session_websocket", discovery_field(endpoints, "session_websocket"),
       session_websocket_schemes(context)},
      {"public_servers", discovery_field(endpoints, "public_servers"), ["http", "https"]},
      {"snapshot_template", discovery_field(endpoints, "snapshot_template"), ["http", "https"]},
      {"profiles", discovery_field(endpoints, "profiles"), ["http", "https"]},
      {"schema_template", discovery_field(endpoints, "schema_template"), ["http", "https"]},
      {"schemas", discovery_field(endpoints, "schemas"), ["http", "https"]}
    ]
    |> Enum.reduce_while({:ok, %{}}, fn {key, value, allowed_schemes}, {:ok, acc} ->
      case maybe_normalize_discovery_endpoint(
             key,
             value,
             validate_urls?,
             claimed_domain,
             allowed_schemes,
             context
           ) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_discovery_endpoints(_endpoints, _claimed_domain, _validate_urls?, _context),
    do: {:error, :invalid_discovery_endpoints}

  defp session_websocket_schemes(context) do
    if call(context, :allow_insecure_transport?, []), do: ["ws", "wss"], else: ["wss"]
  end

  defp maybe_normalize_discovery_endpoint(
         _key,
         value,
         _validate_urls?,
         _claimed_domain,
         _allowed_schemes,
         _context
       )
       when value in [nil, ""] do
    {:ok, nil}
  end

  defp maybe_normalize_discovery_endpoint(
         _key,
         value,
         validate_urls?,
         claimed_domain,
         allowed_schemes,
         context
       ) do
    case normalize_discovery_url(value, validate_urls?, claimed_domain, allowed_schemes, context) do
      normalized when is_binary(normalized) -> {:ok, normalized}
      _ -> {:error, :invalid_discovery_endpoints}
    end
  end

  defp normalize_discovery_capabilities(payload) when is_map(payload) do
    features = normalize_discovery_features(discovery_field(payload, "features"))
    limits = normalize_discovery_limits(discovery_field(payload, "limits"))

    transport_profiles =
      normalize_discovery_transport_profiles(discovery_field(payload, "transport_profiles"))

    features
    |> maybe_put_discovery_capability("limits", limits)
    |> maybe_put_discovery_capability("transport_profiles", transport_profiles)
  end

  defp normalize_discovery_capabilities(_payload), do: %{}

  defp maybe_put_discovery_capability(map, _key, nil), do: map
  defp maybe_put_discovery_capability(map, _key, %{} = value) when map_size(value) == 0, do: map

  defp maybe_put_discovery_capability(map, key, value) when is_map(map) and is_binary(key) do
    Map.put(map, key, value)
  end

  defp normalize_discovery_features(features) when is_map(features), do: features
  defp normalize_discovery_features(_features), do: %{}

  defp normalize_discovery_limits(limits) when is_map(limits) do
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
      case discovery_field(limits, key) do
        value when is_integer(value) and value > 0 -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp normalize_discovery_limits(_limits), do: %{}

  defp normalize_discovery_transport_profiles(profiles) when is_map(profiles) do
    preferred_order =
      profiles
      |> discovery_field("preferred_order")
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    fallback_order =
      profiles
      |> discovery_field("fallback_order")
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    %{}
    |> maybe_put_discovery_capability(
      "preferred_order",
      if(preferred_order == [], do: nil, else: preferred_order)
    )
    |> maybe_put_discovery_capability(
      "fallback_order",
      if(fallback_order == [], do: nil, else: fallback_order)
    )
    |> maybe_put_discovery_capability(
      "session_websocket",
      case discovery_field(profiles, "session_websocket") do
        %{} = session_profile -> session_profile
        _ -> nil
      end
    )
  end

  defp normalize_discovery_transport_profiles(_profiles), do: %{}

  defp discovery_identity_fingerprint(%{"keys" => keys, "current_key_id" => current_key_id})
       when is_list(keys) do
    normalized =
      keys
      |> Enum.map(fn key ->
        %{"id" => discovery_field(key, "id"), "public_key" => discovery_field(key, "public_key")}
      end)
      |> Enum.sort_by(&{&1["id"] || "", &1["public_key"] || ""})

    :crypto.hash(
      :sha256,
      Jason.encode!(%{"current_key_id" => current_key_id, "keys" => normalized})
    )
    |> Base.url_encode64(padding: false)
  end

  defp discovery_identity_fingerprint(_identity), do: ""

  defp verify_discovery_bootstrap_trust(domain, identity, identity_fingerprint, context)
       when is_binary(domain) and is_map(identity) and is_binary(identity_fingerprint) and
              is_map(context) do
    case configured_trust_anchor(domain, context) do
      anchor when is_binary(anchor) ->
        if anchor == identity_fingerprint do
          :ok
        else
          {:error, :identity_anchor_mismatch}
        end

      nil ->
        current_record = get_discovered_peer_record(domain)

        current_fingerprint =
          current_record && normalize_optional_string(current_record.identity_fingerprint)

        cond do
          is_binary(current_fingerprint) and current_fingerprint == identity_fingerprint ->
            :ok

          dns_identity_proof_matches?(domain, identity, identity_fingerprint, context) ->
            :ok

          dns_identity_proof_present?(domain, context) ->
            {:error, :identity_dns_proof_failed}

          true ->
            {:error, :bootstrap_trust_not_verified}
        end
    end
  end

  defp verify_discovery_bootstrap_trust(_domain, _identity, _identity_fingerprint, _context),
    do: {:error, :bootstrap_trust_not_verified}

  defp configured_trust_anchor(domain, context) when is_binary(domain) and is_map(context) do
    anchors =
      call(context, :federation_config, [])
      |> Keyword.get(:trust_anchors, %{})

    case anchors do
      %{} = map ->
        map
        |> Map.get(String.downcase(domain))
        |> normalize_optional_string()

      list when is_list(list) ->
        list
        |> Enum.reduce(%{}, fn
          {key, value}, acc ->
            Map.put(acc, String.downcase(to_string(key)), value)

          %{} = value, acc ->
            mapped_domain = normalize_optional_string(value[:domain] || value["domain"])
            fingerprint = normalize_optional_string(value[:fingerprint] || value["fingerprint"])

            if is_binary(mapped_domain) and is_binary(fingerprint) do
              Map.put(acc, String.downcase(mapped_domain), fingerprint)
            else
              acc
            end

          _value, acc ->
            acc
        end)
        |> Map.get(String.downcase(domain))
        |> normalize_optional_string()

      _ ->
        nil
    end
  end

  defp configured_trust_anchor(_domain, _context), do: nil

  defp dns_identity_proof_matches?(domain, identity, identity_fingerprint, context)
       when is_binary(domain) and is_map(identity) and is_binary(identity_fingerprint) and
              is_map(context) do
    public_keys =
      identity
      |> discovery_field("keys")
      |> List.wrap()
      |> Enum.map(&normalize_optional_string(discovery_field(&1, "public_key")))
      |> Enum.reject(&is_nil/1)

    domain
    |> discovery_dns_identity_proofs(context)
    |> Enum.any?(fn proof ->
      dns_identity_record_matches?(
        proof,
        identity_fingerprint,
        public_keys,
        discovery_tls_identity_binding(domain, context)
      )
    end)
  end

  defp dns_identity_proof_matches?(_domain, _identity, _identity_fingerprint, _context), do: false

  defp dns_identity_proof_present?(domain, context) when is_binary(domain) and is_map(context) do
    discovery_dns_identity_proofs(domain, context) != []
  end

  defp dns_identity_proof_present?(_domain, _context), do: false

  defp discovery_dns_identity_proofs(domain, context)
       when is_binary(domain) and is_map(context) do
    case call(context, :federation_config, []) |> Keyword.get(:dns_identity_fetcher) do
      fun when is_function(fun, 2) ->
        ["_arblarg.#{domain}", "_arblarg-bootstrap.#{domain}"]
        |> Enum.flat_map(fn name ->
          case fun.(name, domain) do
            records when is_list(records) -> Enum.map(records, &normalize_dns_identity_proof/1)
            record -> [normalize_dns_identity_proof(record)]
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      fun when is_function(fun, 1) ->
        ["_arblarg.#{domain}", "_arblarg-bootstrap.#{domain}"]
        |> Enum.flat_map(fn name ->
          case fun.(name) do
            records when is_list(records) -> Enum.map(records, &normalize_dns_identity_proof/1)
            record -> [normalize_dns_identity_proof(record)]
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        ["_arblarg.#{domain}", "_arblarg-bootstrap.#{domain}"]
        |> Enum.flat_map(&lookup_dns_txt_records/1)
        |> Enum.map(&normalize_dns_identity_proof/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    end
  rescue
    _ -> []
  end

  defp discovery_dns_identity_proofs(_domain, _context), do: []

  defp normalize_dns_identity_proof(%{} = proof) do
    text =
      normalize_optional_string(proof[:text] || proof["text"] || proof[:value] || proof["value"])

    if is_binary(text) do
      %{
        text: text,
        authenticated:
          truthy_feature_flag?(proof[:authenticated] || proof["authenticated"] || false)
      }
    else
      nil
    end
  end

  defp normalize_dns_identity_proof(record) when is_binary(record) do
    case normalize_optional_string(record) do
      nil -> nil
      text -> %{text: text, authenticated: false}
    end
  end

  defp normalize_dns_identity_proof(_record), do: nil

  defp dns_identity_record_matches?(proof, identity_fingerprint, public_keys, tls_binding)
       when is_map(proof) and is_binary(identity_fingerprint) and is_list(public_keys) do
    normalized = String.downcase(String.trim(proof.text || ""))
    fingerprint = String.downcase(identity_fingerprint)

    identity_match? =
      normalized == fingerprint or
        String.contains?(normalized, "fingerprint=#{fingerprint}") or
        Enum.any?(public_keys, fn key ->
          downcased_key = String.downcase(key)

          normalized == downcased_key or
            String.contains?(normalized, "public_key=#{downcased_key}") or
            String.contains?(normalized, "key=#{downcased_key}")
        end)

    tls_match? =
      case tls_binding do
        %{"certificate_sha256" => certificate_sha256} ->
          String.contains?(
            normalized,
            "tls_certificate_sha256=#{String.downcase(certificate_sha256)}"
          )

        _ ->
          false
      end

    identity_match? and (proof.authenticated == true or tls_match?)
  end

  defp dns_identity_record_matches?(_proof, _identity_fingerprint, _public_keys, _tls_binding),
    do: false

  defp discovery_tls_identity_binding(domain, context)
       when is_binary(domain) and is_map(context) do
    case call(context, :federation_config, []) |> Keyword.get(:tls_identity_fetcher) do
      fun when is_function(fun, 2) ->
        normalize_tls_identity_binding(fun.(domain, %{scheme: "https", port: 443}))

      fun when is_function(fun, 1) ->
        normalize_tls_identity_binding(fun.(domain))

      _ ->
        lookup_tls_identity_binding(domain)
    end
  rescue
    _ -> nil
  end

  defp discovery_tls_identity_binding(_domain, _context), do: nil

  defp normalize_tls_identity_binding(%{} = binding) do
    certificate_sha256 =
      normalize_optional_string(binding[:certificate_sha256] || binding["certificate_sha256"])

    if is_binary(certificate_sha256) do
      %{"certificate_sha256" => String.downcase(certificate_sha256)}
    else
      nil
    end
  end

  defp normalize_tls_identity_binding(binding) when is_binary(binding) do
    normalize_tls_identity_binding(%{"certificate_sha256" => binding})
  end

  defp normalize_tls_identity_binding(_binding), do: nil

  defp lookup_tls_identity_binding(domain) when is_binary(domain) do
    ssl_opts = [
      :binary,
      active: false,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(domain),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    with {:ok, socket} <- :ssl.connect(String.to_charlist(domain), 443, ssl_opts, 5_000),
         {:ok, cert_der} <- :ssl.peercert(socket) do
      _ = :ssl.close(socket)

      %{
        "certificate_sha256" =>
          cert_der
          |> :crypto.hash(:sha256)
          |> Base.url_encode64(padding: false)
          |> String.downcase()
      }
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp lookup_tls_identity_binding(_domain), do: nil

  defp lookup_dns_txt_records(name) when is_binary(name) do
    name
    |> String.to_charlist()
    |> :inet_res.lookup(:in, :txt)
    |> Enum.map(fn record ->
      record
      |> List.wrap()
      |> Enum.map_join("", &to_string/1)
    end)
  rescue
    _ -> []
  end

  defp lookup_dns_txt_records(_name), do: []

  defp normalize_discovery_url(value, false, claimed_domain, allowed_schemes, _context) do
    case normalize_optional_string(value) do
      nil ->
        nil

      url ->
        case URI.parse(url) do
          %URI{scheme: scheme, host: host} ->
            if is_binary(host) and host != "" and scheme in allowed_schemes and
                 host_belongs_to_domain?(host, claimed_domain) do
              url
            else
              nil
            end

          _ ->
            nil
        end
    end
  end

  defp normalize_discovery_url(value, true, claimed_domain, allowed_schemes, context) do
    with url when is_binary(url) <- normalize_optional_string(value),
         :ok <- validate_discovery_url(url, claimed_domain, allowed_schemes, context) do
      url
    else
      _ -> nil
    end
  end

  defp validate_discovery_url(url, claimed_domain, allowed_schemes, context)
       when is_binary(url) and is_binary(claimed_domain) and is_list(allowed_schemes) and
              is_map(context) do
    with %URI{scheme: scheme, host: host} <- URI.parse(url),
         true <- is_binary(host) and host != "",
         true <- scheme in allowed_schemes,
         :ok <- maybe_validate_httpish_discovery_url(url, scheme, context),
         true <- host_belongs_to_domain?(host, claimed_domain) do
      :ok
    else
      false -> {:error, :invalid_discovery_url}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_discovery_url}
    end
  end

  defp validate_discovery_url(url, context) when is_binary(url) and is_map(context) do
    with :ok <- URLValidator.validate(url),
         %URI{scheme: scheme, host: host} <- URI.parse(url),
         true <- is_binary(host) and host != "",
         true <-
           scheme == "https" or
             (call(context, :allow_insecure_transport?, []) and scheme == "http") do
      :ok
    else
      false -> {:error, :invalid_discovery_url}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_discovery_url}
    end
  end

  defp validate_discovery_url(_url, _context), do: {:error, :invalid_discovery_url}

  defp host_belongs_to_domain?(host, remote_domain)
       when is_binary(host) and is_binary(remote_domain) do
    normalized_host = String.downcase(host)
    normalized_domain = String.downcase(remote_domain)

    normalized_host == normalized_domain or
      String.ends_with?(normalized_host, "." <> normalized_domain)
  end

  defp host_belongs_to_domain?(_host, _remote_domain), do: false

  defp maybe_validate_httpish_discovery_url(url, scheme, context)
       when scheme in ["http", "https"] do
    with :ok <- URLValidator.validate(url),
         true <-
           scheme == "https" or
             (call(context, :allow_insecure_transport?, []) and scheme == "http") do
      :ok
    else
      false -> {:error, :invalid_discovery_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_validate_httpish_discovery_url(_url, "wss", _context), do: :ok

  defp maybe_validate_httpish_discovery_url(_url, "ws", context) do
    if call(context, :allow_insecure_transport?, []),
      do: :ok,
      else: {:error, :invalid_discovery_url}
  end

  defp extract_discovery_base_url(
         endpoints,
         discovery_url,
         claimed_domain,
         validate_urls?,
         context
       )
       when is_map(endpoints) and is_binary(discovery_url) and is_binary(claimed_domain) and
              is_map(context) do
    [
      Map.get(endpoints, "events_batch"),
      Map.get(endpoints, "events"),
      Map.get(endpoints, "sync"),
      Map.get(endpoints, "stream_events"),
      Map.get(endpoints, "public_servers"),
      Map.get(endpoints, "well_known"),
      normalize_discovery_url(
        discovery_url,
        validate_urls?,
        claimed_domain,
        ["http", "https"],
        context
      )
    ]
    |> Enum.find_value(&base_url_from_remote_url/1)
  end

  defp extract_discovery_base_url(
         _endpoints,
         discovery_url,
         claimed_domain,
         validate_urls?,
         context
       ) do
    base_url_from_remote_url(
      normalize_discovery_url(
        discovery_url,
        validate_urls?,
        claimed_domain,
        ["http", "https"],
        context
      )
    )
  end

  defp base_url_from_remote_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        default_port? =
          (scheme == "https" and port in [nil, 443]) or
            (scheme == "http" and port in [nil, 80])

        if default_port? do
          "#{scheme}://#{host}"
        else
          "#{scheme}://#{host}:#{port}"
        end

      _ ->
        nil
    end
  end

  defp base_url_from_remote_url(_url), do: nil

  defp upsert_discovered_peer(attrs) when is_map(attrs) do
    record =
      get_discovered_peer_record(attrs.domain) ||
        %FederationDiscoveredPeer{}

    attrs = merge_discovered_peer_continuity(record, attrs)

    record
    |> FederationDiscoveredPeer.changeset(attrs)
    |> Repo.insert_or_update()
  rescue
    _ ->
      {:error, :discovered_peer_store_unavailable}
  end

  defp upsert_discovered_peer(_attrs), do: {:error, :invalid_discovered_peer}

  defp get_discovered_peer_record(domain) when is_binary(domain) do
    Repo.get_by(FederationDiscoveredPeer, domain: domain)
  rescue
    _ ->
      nil
  end

  defp get_discovered_peer_record(_domain), do: nil

  defp merge_discovered_peer_continuity(%FederationDiscoveredPeer{} = record, attrs)
       when is_map(attrs) do
    current_fingerprint = normalize_optional_string(record.identity_fingerprint)
    new_fingerprint = normalize_optional_string(attrs.identity_fingerprint)
    now = attrs.last_discovered_at || DateTime.utc_now() |> DateTime.truncate(:second)

    cond do
      is_nil(current_fingerprint) or is_nil(new_fingerprint) or
          current_fingerprint == new_fingerprint ->
        attrs
        |> Map.put(:trust_state, record.trust_state || attrs.trust_state || "trusted")
        |> Map.put(:previous_identity_fingerprint, record.previous_identity_fingerprint)
        |> Map.put(:last_key_change_at, record.last_key_change_at)

      discovery_identity_overlaps?(record.identity, attrs.identity) ->
        attrs
        |> Map.put(:trust_state, "rotated")
        |> Map.put(:previous_identity_fingerprint, current_fingerprint)
        |> Map.put(:last_key_change_at, now)

      true ->
        attrs
        |> Map.put(:trust_state, "replaced")
        |> Map.put(:previous_identity_fingerprint, current_fingerprint)
        |> Map.put(:last_key_change_at, now)
    end
  end

  defp merge_discovered_peer_continuity(_record, attrs) when is_map(attrs), do: attrs

  defp discovery_identity_overlaps?(left, right) when is_map(left) and is_map(right) do
    left_keys =
      left
      |> discovery_field("keys")
      |> List.wrap()
      |> Enum.map(&normalize_optional_string(discovery_field(&1, "public_key")))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    right_keys =
      right
      |> discovery_field("keys")
      |> List.wrap()
      |> Enum.map(&normalize_optional_string(discovery_field(&1, "public_key")))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    not MapSet.disjoint?(left_keys, right_keys)
  end

  defp discovery_identity_overlaps?(_left, _right), do: false

  defp build_discovered_peer(%FederationDiscoveredPeer{} = record, context)
       when is_map(context) do
    {allow_incoming, allow_outgoing} = discovered_peer_permissions(record.trust_state)

    peer_attrs = %{
      domain: record.domain,
      base_url: record.base_url,
      keys:
        case record.identity do
          %{"keys" => keys} when is_list(keys) -> keys
          %{keys: keys} when is_list(keys) -> keys
          _ -> []
        end,
      active_outbound_key_id:
        normalize_optional_string(discovery_field(record.identity || %{}, "current_key_id")),
      allow_incoming: allow_incoming,
      allow_outgoing: allow_outgoing,
      event_endpoint: discovery_field(record.endpoints || %{}, "events"),
      events_batch_endpoint: discovery_field(record.endpoints || %{}, "events_batch"),
      ephemeral_endpoint: discovery_field(record.endpoints || %{}, "ephemeral"),
      sync_endpoint: discovery_field(record.endpoints || %{}, "sync"),
      directory_endpoint: discovery_field(record.endpoints || %{}, "public_servers"),
      stream_events_endpoint: discovery_field(record.endpoints || %{}, "stream_events"),
      session_websocket_endpoint: discovery_field(record.endpoints || %{}, "session_websocket"),
      snapshot_endpoint_template: discovery_field(record.endpoints || %{}, "snapshot_template")
    }

    case Config.normalize_peer_config(peer_attrs, call(context, :allow_insecure_transport?, [])) do
      %{} = peer ->
        peer
        |> Map.put(:discovery_source, :dynamic)
        |> Map.put(:discovered, true)
        |> Map.put(:discovery_url, record.discovery_url)
        |> Map.put(:last_discovered_at, record.last_discovered_at)
        |> Map.put(:trust_state, record.trust_state)
        |> Map.put(:identity_fingerprint, record.identity_fingerprint)
        |> Map.put(:previous_identity_fingerprint, record.previous_identity_fingerprint)
        |> Map.put(:last_key_change_at, record.last_key_change_at)
        |> Map.put(:features, record.features || %{})
        |> apply_runtime_policy_to_peer()

      _ ->
        nil
    end
  end

  defp build_discovered_peer(_record, _context), do: nil

  defp build_discovered_peer_control(%FederationDiscoveredPeer{} = peer, context) do
    effective_peer = build_discovered_peer(peer, context)

    %{
      domain: peer.domain,
      configured: false,
      discovered: true,
      base_url: peer.base_url,
      discovery_url: peer.discovery_url,
      blocked: peer.trust_state == "replaced",
      reason: peer.last_error,
      allow_incoming_override: nil,
      allow_outgoing_override: nil,
      effective_allow_incoming:
        if(is_map(effective_peer), do: effective_peer.allow_incoming == true, else: false),
      effective_allow_outgoing:
        if(is_map(effective_peer), do: effective_peer.allow_outgoing == true, else: false),
      updated_at: peer.updated_at,
      updated_by: nil,
      trust_state: peer.trust_state,
      protocol_version: peer.protocol_version,
      features: peer.features || %{},
      last_discovered_at: peer.last_discovered_at,
      last_key_change_at: peer.last_key_change_at,
      requires_operator_action: peer.trust_state == "replaced"
    }
  end

  defp maybe_filter_discovered_search(query, search_query) when is_binary(search_query) do
    case String.trim(search_query) do
      "" -> query
      trimmed -> where(query, [peer], ilike(peer.domain, ^"%#{trimmed}%"))
    end
  end

  defp maybe_filter_discovered_search(query, _search_query), do: query

  defp maybe_filter_discovered_domains(query, domains) when is_list(domains) do
    normalized_domains =
      domains
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.downcase/1)
      |> Enum.uniq()

    case normalized_domains do
      [] -> where(query, [peer], false)
      _ -> where(query, [peer], peer.domain in ^normalized_domains)
    end
  end

  defp maybe_filter_discovered_domains(query, _domains), do: query

  defp discovered_peer_permissions(trust_state) do
    case normalize_optional_string(trust_state) do
      "replaced" -> {false, false}
      _ -> {true, true}
    end
  end

  defp apply_runtime_policy_to_peer(peer) when is_map(peer) do
    [peer]
    |> PeerPolicies.apply_runtime_policies()
    |> List.first()
  end

  defp apply_runtime_policy_to_peer(_peer), do: nil

  defp discovered_peer_stale?(
         %FederationDiscoveredPeer{last_discovered_at: %DateTime{} = discovered_at},
         context
       )
       when is_map(context) do
    DateTime.diff(DateTime.utc_now(), discovered_at, :second) >
      call(context, :discovery_ttl_seconds, [])
  end

  defp discovered_peer_stale?(_record, _context), do: true

  defp discovered_peer_within_grace?(
         %FederationDiscoveredPeer{last_discovered_at: %DateTime{} = discovered_at},
         context
       )
       when is_map(context) do
    DateTime.diff(DateTime.utc_now(), discovered_at, :second) <=
      call(context, :discovery_stale_grace_seconds, [])
  end

  defp discovered_peer_within_grace?(_record, _context), do: false

  defp record_discovery_failure(domain, reason) when is_binary(domain) do
    case get_discovered_peer_record(domain) do
      %FederationDiscoveredPeer{} = record ->
        record
        |> FederationDiscoveredPeer.changeset(%{last_error: inspect(reason)})
        |> Repo.update()

      _ ->
        :ok
    end
  rescue
    _ ->
      :ok
  end

  defp record_discovery_failure(_domain, _reason), do: :ok

  defp discovery_candidate_urls(domain, context) when is_binary(domain) and is_map(context) do
    schemes =
      if call(context, :allow_insecure_transport?, []) do
        ["https", "http"]
      else
        ["https"]
      end

    Enum.flat_map(schemes, fn scheme ->
      base = "#{scheme}://#{domain}"

      [
        "#{base}/.well-known/arblarg",
        "#{base}/.well-known/arblarg/#{ArblargSDK.protocol_version()}"
      ]
    end)
  end

  defp discovery_candidate_urls(_domain, _context), do: []

  defp discovery_field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      case safe_existing_atom_key(key) do
        nil -> nil
        atom_key -> Map.get(map, atom_key)
      end
  end

  defp discovery_field(_map, _key), do: nil

  defp safe_existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    _ ->
      nil
  end

  defp safe_existing_atom_key(_key), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_value), do: nil

  defp truthy_feature_flag?(value)
       when value in [true, 1, "1", "true", "TRUE", "yes", "YES"],
       do: true

  defp truthy_feature_flag?(_value), do: false

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
