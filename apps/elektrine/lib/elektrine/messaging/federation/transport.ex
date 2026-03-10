defmodule Elektrine.Messaging.Federation.Transport do
  @moduledoc false

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

  defp truthy_feature_flag?(value)
       when value in [true, 1, "1", "true", "TRUE", "yes", "YES"],
       do: true

  defp truthy_feature_flag?(_value), do: false
end
