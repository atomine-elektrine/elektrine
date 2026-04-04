defmodule Elektrine.IpLookup do
  @moduledoc """
  Provides IP address geolocation lookup functionality.
  Uses ip-api.com free service.
  """

  require Logger
  alias Elektrine.HTTP.SafeFetch

  @doc """
  Looks up geolocation information for an IP address.
  Returns {:ok, map} with location data or {:error, reason}.
  """
  def lookup(ip_address) when is_binary(ip_address) do
    # Check if it's a private/local IP first
    if private_ip?(ip_address) do
      {:ok,
       %{
         ip: ip_address,
         country: "Local/Private",
         country_code: "N/A",
         region: "N/A",
         city: get_private_ip_description(ip_address),
         zip: nil,
         latitude: nil,
         longitude: nil,
         timezone: nil,
         isp: "Private Network",
         org: nil,
         as: nil
       }}
    else
      url = "https://ipwho.is/#{URI.encode_www_form(ip_address)}"

      request = Finch.build(:get, url)

      case SafeFetch.request(request, Elektrine.Finch, receive_timeout: 10_000) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"success" => true} = data} ->
              {:ok, format_lookup_result(data)}

            {:ok, %{"success" => false, "message" => message}} ->
              {:error, message}

            {:ok, _} ->
              {:error, "Invalid response from geolocation service"}

            {:error, _} ->
              {:error, "Failed to parse response"}
          end

        {:ok, %Finch.Response{status: status}} ->
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          Logger.error("IP lookup failed for #{ip_address}: #{inspect(reason)}")
          {:error, "Network error: #{inspect(reason)}"}
      end
    end
  end

  defp private_ip?(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {10, _, _, _}} ->
        true

      {:ok, {172, second, _, _}} when second >= 16 and second <= 31 ->
        true

      {:ok, {192, 168, _, _}} ->
        true

      {:ok, {127, _, _, _}} ->
        true

      {:ok, {169, 254, _, _}} ->
        true

      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} ->
        true

      {:ok, {0, 0, 0, 0, 0, 65_535, 127, _}} ->
        true

      {:ok, {first, second, _, _, _, _, _, _}} ->
        unique_local_ipv6?(first) or link_local_ipv6?(first, second)

      _ ->
        false
    end
  end

  defp unique_local_ipv6?(first), do: first >= 64_512 and first <= 65_023

  defp link_local_ipv6?(65_152, second), do: second >= 32_768 and second <= 49_151
  defp link_local_ipv6?(_, _), do: false

  defp get_private_ip_description(ip) do
    cond do
      String.starts_with?(ip, "127.") -> "Localhost/Loopback"
      String.starts_with?(ip, "10.") -> "Private Network (Class A)"
      String.starts_with?(ip, "192.168.") -> "Private Network (Class C)"
      String.starts_with?(ip, "172.") -> "Private Network (Class B)"
      String.starts_with?(ip, "169.254.") -> "Link-Local Address"
      true -> "Private/Reserved Range"
    end
  end

  defp format_lookup_result(data) do
    %{
      ip: data["ip"],
      country: data["country"],
      country_code: data["country_code"],
      region: data["region"],
      city: data["city"],
      zip: data["postal"],
      latitude: data["latitude"],
      longitude: data["longitude"],
      timezone: get_in(data, ["timezone", "id"]),
      isp: get_in(data, ["connection", "isp"]),
      org: get_in(data, ["connection", "org"]),
      as: format_as_number(get_in(data, ["connection", "asn"]))
    }
  end

  defp format_as_number(asn) when is_integer(asn), do: "AS#{asn}"
  defp format_as_number(asn) when is_binary(asn), do: asn
  defp format_as_number(_), do: nil
end
