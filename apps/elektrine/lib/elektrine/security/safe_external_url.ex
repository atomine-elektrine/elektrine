defmodule Elektrine.Security.SafeExternalURL do
  @moduledoc false

  alias Elektrine.Security.URLValidator

  def normalize(url) when is_binary(url) do
    normalized = String.trim(url)

    if Regex.match?(~r/[\x00-\x1F\x7F]/, normalized) do
      {:error, :invalid_url}
    else
      case URI.parse(normalized) do
        %URI{scheme: scheme, host: host, userinfo: nil}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          case URLValidator.validate(normalized) do
            :ok -> {:ok, normalized}
            {:error, reason} -> {:error, reason}
          end

        %URI{userinfo: userinfo} when not is_nil(userinfo) ->
          {:error, :userinfo_not_allowed}

        _ ->
          {:error, :invalid_url}
      end
    end
  end

  def normalize(_), do: {:error, :invalid_url}

  def normalize_href(url) when is_binary(url) do
    normalized = String.trim(url)

    if Regex.match?(~r/[\x00-\x1F\x7F]/, normalized) do
      {:error, :invalid_url}
    else
      case URI.parse(normalized) do
        %URI{scheme: scheme, host: host, userinfo: nil} = parsed
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          {:ok, URI.to_string(parsed)}

        %URI{userinfo: userinfo} when not is_nil(userinfo) ->
          {:error, :userinfo_not_allowed}

        _ ->
          {:error, :invalid_url}
      end
    end
  end

  def normalize_href(_), do: {:error, :invalid_url}
end
