defmodule Elektrine.IpLookup do
  @moduledoc """
  Provides IP address geolocation lookup functionality.
  Uses ip-api.com free service.
  """

  require Logger

  @doc """
  Looks up geolocation information for an IP address.
  Returns {:ok, map} with location data or {:error, reason}.
  """
  def lookup(ip_address) when is_binary(ip_address) do
    # Check if it's a private/local IP first
    if is_private_ip?(ip_address) do
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
      url =
        "http://ip-api.com/json/#{ip_address}?fields=status,message,country,countryCode,region,regionName,city,zip,lat,lon,timezone,isp,org,as,query"

      request = Finch.build(:get, url)

      case Finch.request(request, Elektrine.Finch, receive_timeout: 10_000) do
        {:ok, %Finch.Response{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"status" => "success"} = data} ->
              {:ok, format_lookup_result(data)}

            {:ok, %{"status" => "fail", "message" => message}} ->
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

  defp is_private_ip?(ip) do
    case String.split(ip, ".") do
      # IPv4 private ranges
      ["10" | _] ->
        true

      ["172", second | _] ->
        case Integer.parse(second) do
          {num, _} when num >= 16 and num <= 31 -> true
          _ -> false
        end

      ["192", "168" | _] ->
        true

      # Loopback
      ["127" | _] ->
        true

      # Link-local
      ["169", "254" | _] ->
        true

      _ ->
        false
    end
  end

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
      ip: data["query"],
      country: data["country"],
      country_code: data["countryCode"],
      region: data["regionName"],
      city: data["city"],
      zip: data["zip"],
      latitude: data["lat"],
      longitude: data["lon"],
      timezone: data["timezone"],
      isp: data["isp"],
      org: data["org"],
      as: data["as"]
    }
  end
end
