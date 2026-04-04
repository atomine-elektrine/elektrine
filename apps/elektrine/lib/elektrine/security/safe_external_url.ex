defmodule Elektrine.Security.SafeExternalURL do
  @moduledoc false

  alias Elektrine.Security.URLValidator

  def normalize(url) when is_binary(url) do
    normalized = String.trim(url)

    case URI.parse(normalized) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        case URLValidator.validate(normalized) do
          :ok -> {:ok, normalized}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :invalid_url}
    end
  end

  def normalize(_), do: {:error, :invalid_url}
end
