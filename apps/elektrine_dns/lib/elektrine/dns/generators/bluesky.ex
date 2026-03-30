defmodule Elektrine.DNS.Generators.Bluesky do
  @moduledoc false

  def generate(zone, settings \\ %{}) do
    ttl = zone.default_ttl || 300

    [
      %{
        managed_key: "bluesky:host",
        name: bluesky_host_label(settings),
        type: "CNAME",
        ttl: ttl,
        content: bluesky_target(zone, settings),
        required: false,
        metadata: %{"label" => "Bluesky host alias"}
      }
    ]
  end

  defp bluesky_host_label(settings) do
    case Map.get(settings, "bluesky_host") do
      value when is_binary(value) and value != "" -> normalize(value, "bsky")
      _ -> "bsky"
    end
  end

  defp bluesky_target(zone, settings) do
    case Map.get(settings, "bluesky_target") do
      value when is_binary(value) and value != "" -> normalize(value, zone.domain)
      _ -> zone.domain
    end
  end

  defp normalize(value, fallback) do
    case value |> String.trim() |> String.trim_trailing(".") |> String.downcase() do
      "" -> fallback
      normalized -> normalized
    end
  end
end
