defmodule ElektrineWeb.UrlHelpers do
  @moduledoc false

  alias Elektrine.Security.SafeExternalURL

  @control_chars ~r/[\x00-\x1F\x7F]/
  @media_local_prefixes ["/uploads/", "/api/private-attachments/"]

  def safe_optional_media_url(url, opts \\ []) do
    case safe_media_url(url, opts) do
      {:ok, safe_url} -> safe_url
      {:error, _reason} -> nil
    end
  end

  def safe_media_url(url, opts \\ [])

  def safe_media_url(url, opts) when is_binary(url) do
    trimmed = String.trim(url)
    local_paths = Keyword.get(opts, :local_paths, :media_only)

    cond do
      trimmed == "" ->
        {:error, :empty_url}

      Regex.match?(@control_chars, trimmed) ->
        {:error, :invalid_url}

      String.starts_with?(trimmed, "uploads/") ->
        {:ok, "/" <> trimmed}

      local_media_path?(trimmed) ->
        {:ok, trimmed}

      local_paths == :any and String.starts_with?(trimmed, "/") and
          not String.starts_with?(trimmed, "//") ->
        {:ok, trimmed}

      Keyword.get(opts, :external, :validated) == :href ->
        SafeExternalURL.normalize_href(trimmed)

      true ->
        SafeExternalURL.normalize(trimmed)
    end
  end

  def safe_media_url(_url, _opts), do: {:error, :invalid_url}

  def host_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  def host_from_url(_url), do: nil

  defp local_media_path?(url) when is_binary(url) do
    String.starts_with?(url, @media_local_prefixes)
  end
end
