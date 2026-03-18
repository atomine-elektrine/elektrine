defmodule Elektrine.Messaging.Federation.Transport do
  @moduledoc false

  alias Elektrine.Messaging.{ArblargProfiles, ArblargSDK}

  @fallback_statuses [404, 406, 410, 415, 426, 501]
  @supported_transports [
    "session_websocket",
    "events_batch_cbor",
    "events_batch_json",
    "events_json"
  ]

  def event_result_success?(%{"status" => status}, successful_statuses)
      when is_binary(status) and is_struct(successful_statuses, MapSet) do
    MapSet.member?(successful_statuses, status)
  end

  def event_result_success?(_result, _successful_statuses), do: false

  def peer_supports?(peer, feature, default) when is_map(peer) and is_binary(feature) do
    case Map.fetch(peer_features(peer), feature) do
      {:ok, value} -> truthy_feature_flag?(value)
      :error -> default
    end
  end

  def peer_supports?(_peer, _feature, default), do: default

  def peer_supports_event_type?(peer, event_type) when is_map(peer) and is_binary(event_type) do
    canonical_event_type = ArblargSDK.canonical_event_type(event_type)

    cond do
      canonical_event_type in ArblargSDK.core_event_types() ->
        true

      canonical_event_type in ArblargSDK.supported_event_types() ->
        supported_event_type_advertised?(peer, canonical_event_type) or
          supported_extension_advertised?(
            peer,
            ArblargProfiles.extension_urn_for_event_type(canonical_event_type)
          ) or
          supported_profile_advertised?(
            peer,
            ArblargProfiles.required_profile_for_event_type(canonical_event_type)
          )

      true ->
        false
    end
  end

  def peer_supports_event_type?(_peer, _event_type), do: false

  def event_transport_order(peer, transport_profiles)
      when is_map(peer) and is_map(transport_profiles) do
    preferred = peer_preferred_transport_order(peer)
    fallback = peer_fallback_transport_order(peer)

    advertised_fallback =
      transport_profiles
      |> Map.get("fallback_order", [])
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    (preferred ++ fallback ++ advertised_fallback)
    |> Enum.filter(&(&1 in @supported_transports))
    |> Enum.uniq()
  end

  def event_transport_order(_peer, _transport_profiles), do: default_transport_order()

  def ephemeral_transport_order(peer, transport_profiles)
      when is_map(peer) and is_map(transport_profiles) do
    event_transport_order(peer, transport_profiles)
  end

  def ephemeral_transport_order(_peer, _transport_profiles), do: default_transport_order()

  def peer_batch_limit(peer, default), do: peer_limit(peer, "max_batch_events", default)

  def peer_ephemeral_limit(peer, default),
    do: peer_limit(peer, "max_ephemeral_items", default)

  def transport_fallback_reason?({:http_error, status, _body}) when status in @fallback_statuses,
    do: true

  def transport_fallback_reason?({:http_error, status}) when status in @fallback_statuses,
    do: true

  def transport_fallback_reason?(:session_transport_unavailable), do: true
  def transport_fallback_reason?(:session_transport_failed), do: true
  def transport_fallback_reason?(:session_closed), do: true
  def transport_fallback_reason?(:session_timeout), do: true
  def transport_fallback_reason?(:unsupported_transport_profile), do: true
  def transport_fallback_reason?(:no_compatible_transport), do: true
  def transport_fallback_reason?(_reason), do: false

  defp default_transport_order do
    ["events_batch_cbor", "events_batch_json", "events_json"]
  end

  defp peer_preferred_transport_order(peer) when is_map(peer) do
    peer
    |> peer_transport_profiles()
    |> Map.get("preferred_order", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp peer_preferred_transport_order(_peer), do: []

  defp peer_fallback_transport_order(peer) when is_map(peer) do
    peer
    |> peer_transport_profiles()
    |> Map.get("fallback_order", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp peer_fallback_transport_order(_peer), do: []

  defp peer_transport_profiles(peer) when is_map(peer) do
    peer_features(peer)
    |> Map.get("transport_profiles", %{})
    |> case do
      %{} = profiles -> profiles
      _ -> %{}
    end
  end

  defp peer_transport_profiles(_peer), do: %{}

  defp peer_limit(peer, key, default) when is_map(peer) and is_binary(key) do
    case peer_features(peer) do
      %{"limits" => %{} = limits} ->
        case Map.get(limits, key) do
          value when is_integer(value) and value > 0 -> value
          _ -> default
        end

      _ ->
        default
    end
  end

  defp peer_limit(_peer, _key, default), do: default

  defp peer_features(peer) when is_map(peer) do
    case Map.get(peer, :features) || Map.get(peer, "features") do
      features when is_map(features) ->
        Enum.reduce(features, %{}, fn {key, value}, acc ->
          normalized_key =
            case key do
              binary when is_binary(binary) -> binary
              atom when is_atom(atom) -> Atom.to_string(atom)
              other -> to_string(other)
            end

          Map.put(acc, normalized_key, value)
        end)

      _ ->
        %{}
    end
  end

  defp peer_features(_peer), do: %{}

  defp supported_event_type_advertised?(peer, event_type) when is_binary(event_type) do
    event_type in peer_supported_event_types(peer)
  end

  defp supported_event_type_advertised?(_peer, _event_type), do: false

  defp supported_extension_advertised?(peer, urn) when is_binary(urn) do
    peer
    |> peer_extensions()
    |> Enum.any?(&extension_supports_urn?(&1, urn))
  end

  defp supported_extension_advertised?(_peer, _urn), do: false

  defp supported_profile_advertised?(peer, profile_id) when is_binary(profile_id) do
    profile_id in peer_compatibility_claims(peer)
  end

  defp supported_profile_advertised?(_peer, _profile_id), do: false

  defp peer_supported_event_types(peer) when is_map(peer) do
    direct_supported =
      capability_list(peer, "supported_event_types")
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&ArblargSDK.canonical_event_type/1)

    event_supported =
      peer_features(peer)
      |> Map.get("events", %{})
      |> case do
        %{} = events -> Map.get(events, "supported", [])
        _ -> []
      end
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&ArblargSDK.canonical_event_type/1)

    Enum.uniq(direct_supported ++ event_supported)
  end

  defp peer_supported_event_types(_peer), do: []

  defp peer_extensions(peer) when is_map(peer) do
    capability_list(peer, "extensions")
  end

  defp peer_extensions(_peer), do: []

  defp peer_compatibility_claims(peer) when is_map(peer) do
    capability_list(peer, "compatibility_claims")
    |> Enum.filter(&is_binary/1)
  end

  defp peer_compatibility_claims(_peer), do: []

  defp capability_list(peer, key) when is_map(peer) and is_binary(key) do
    direct =
      case capability_value(peer, key) do
        values when is_list(values) -> values
        _ -> []
      end

    nested =
      peer_features(peer)
      |> Map.get(key, [])
      |> case do
        values when is_list(values) -> values
        _ -> []
      end

    direct ++ nested
  end

  defp capability_list(_peer, _key), do: []

  defp capability_value(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil ->
        map
        |> Enum.find(fn
          {atom_key, _value} when is_atom(atom_key) -> Atom.to_string(atom_key) == key
          _ -> false
        end)
        |> case do
          {_, value} -> value
          nil -> nil
        end

      value ->
        value
    end
  end

  defp extension_supports_urn?(extension, urn) when is_binary(extension) and is_binary(urn) do
    extension == urn
  end

  defp extension_supports_urn?(%{} = extension, urn) when is_binary(urn) do
    advertised_urn = extension["urn"] || extension[:urn]

    cond do
      advertised_urn != urn ->
        false

      Map.get(extension, "supported") in [true, "true", "1", 1] ->
        true

      Map.get(extension, :supported) in [true, "true", "1", 1] ->
        true

      true ->
        case get_in(extension, ["conformance", "status"]) ||
               get_in(extension, [:conformance, :status]) do
          nil -> true
          status when status in ["passing", "supported", "compatible"] -> true
          _ -> false
        end
    end
  end

  defp extension_supports_urn?(_extension, _urn), do: false

  defp truthy_feature_flag?(value)
       when value in [true, 1, "1", "true", "TRUE", "yes", "YES"],
       do: true

  defp truthy_feature_flag?(_value), do: false
end
