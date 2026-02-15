defmodule ElektrineWeb.Plugs.HTTPSignaturePlug do
  @moduledoc """
  Plug that validates HTTP signatures on incoming ActivityPub requests.

  This plug:
  1. Parses the Signature header
  2. Fetches the signing key (from cache or remote)
  3. Validates the signature
  4. Assigns :valid_signature and :signature_actor to the conn

  The actual enforcement (rejecting unsigned requests) is handled by
  EnsureHTTPSignaturePlug, allowing for flexible authorization modes.
  """

  import Plug.Conn
  require Logger

  alias Elektrine.ActivityPub.SigningKey

  def init(opts), do: opts

  # Skip if already validated
  def call(%{assigns: %{valid_signature: true}} = conn, _opts), do: conn

  def call(conn, _opts) do
    case get_req_header(conn, "signature") do
      [signature_header] when is_binary(signature_header) and byte_size(signature_header) > 0 ->
        validate_signature(conn, signature_header)

      _ ->
        Logger.debug("No signature header present")
        conn
    end
  end

  defp validate_signature(conn, signature_header) do
    case parse_signature_header(signature_header) do
      {:ok, %{"keyId" => key_id, "headers" => headers_string, "signature" => signature}} ->
        verify_with_key(conn, key_id, headers_string, signature)

      {:error, reason} ->
        Logger.debug("Failed to parse signature header: #{inspect(reason)}")

        conn
        |> assign(:valid_signature, false)
        |> assign(:signature_error, reason)
    end
  end

  defp verify_with_key(conn, key_id, headers_string, signature) do
    case SigningKey.get_or_fetch_by_key_id(key_id) do
      {:ok, signing_key} ->
        verify_signature_with_key(conn, signing_key, headers_string, signature)

      {:error, reason} ->
        Logger.debug("Failed to fetch signing key #{key_id}: #{inspect(reason)}")

        conn
        |> assign(:valid_signature, false)
        |> assign(:signature_error, {:key_fetch_failed, reason})
    end
  end

  defp verify_signature_with_key(conn, signing_key, headers_string, signature) do
    headers_list = String.split(headers_string, " ")

    case build_signing_string(conn, headers_list) do
      {:ok, signing_string} ->
        if SigningKey.verify(signing_key, signing_string, signature) do
          # Load the associated user or remote actor
          actor = load_actor_for_key(signing_key)

          conn
          |> assign(:valid_signature, true)
          |> assign(:signature_actor, actor)
          |> assign(:signing_key, signing_key)
        else
          Logger.info("Signature verification failed for key #{signing_key.key_id}")

          # Try refreshing the key and verify again
          retry_with_refreshed_key(conn, signing_key, headers_string, signature)
        end

      {:error, :missing_headers, missing} ->
        Logger.warning("Missing headers for signature verification: #{inspect(missing)}")

        conn
        |> assign(:valid_signature, false)
        |> assign(:signature_error, {:missing_headers, missing})
    end
  end

  defp retry_with_refreshed_key(conn, signing_key, headers_string, signature) do
    case SigningKey.refresh_by_key_id(signing_key.key_id) do
      {:ok, refreshed_key} ->
        headers_list = String.split(headers_string, " ")

        case build_signing_string(conn, headers_list) do
          {:ok, signing_string} ->
            if SigningKey.verify(refreshed_key, signing_string, signature) do
              actor = load_actor_for_key(refreshed_key)

              conn
              |> assign(:valid_signature, true)
              |> assign(:signature_actor, actor)
              |> assign(:signing_key, refreshed_key)
            else
              Logger.warning("Signature verification failed even after key refresh")

              conn
              |> assign(:valid_signature, false)
              |> assign(:signature_error, :invalid_signature)
            end

          {:error, :missing_headers, missing} ->
            conn
            |> assign(:valid_signature, false)
            |> assign(:signature_error, {:missing_headers, missing})
        end

      {:error, :too_young} ->
        # Key was recently fetched, don't retry
        conn
        |> assign(:valid_signature, false)
        |> assign(:signature_error, :invalid_signature)

      {:error, _reason} ->
        conn
        |> assign(:valid_signature, false)
        |> assign(:signature_error, :invalid_signature)
    end
  end

  defp load_actor_for_key(%SigningKey{user_id: user_id}) when not is_nil(user_id) do
    Elektrine.Accounts.get_user!(user_id)
  rescue
    Ecto.NoResultsError -> nil
  end

  defp load_actor_for_key(%SigningKey{remote_actor_id: remote_actor_id})
       when not is_nil(remote_actor_id) do
    Elektrine.ActivityPub.get_remote_actor(remote_actor_id)
  end

  defp load_actor_for_key(_), do: nil

  defp parse_signature_header(header) do
    # Parse: keyId="...",algorithm="...",headers="...",signature="..."
    # Handle both comma-separated and comma+space-separated formats
    parts =
      Regex.scan(~r/(\w+)="([^"]*)"/, header)
      |> Enum.map(fn [_, key, value] -> {key, value} end)
      |> Enum.into(%{})

    required_keys = ["keyId", "headers", "signature"]

    if Enum.all?(required_keys, &Map.has_key?(parts, &1)) do
      {:ok, parts}
    else
      {:error, :invalid_signature_header}
    end
  end

  defp build_signing_string(conn, headers_list) do
    results =
      Enum.map(headers_list, fn header_name ->
        case get_header_value(conn, header_name) do
          {:ok, value} -> {:ok, "#{header_name}: #{value}"}
          {:error, :missing} -> {:error, header_name}
        end
      end)

    missing_headers =
      Enum.filter(results, fn
        {:error, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:error, name} -> name end)

    if Enum.empty?(missing_headers) do
      signing_string =
        results
        |> Enum.map_join("\n", fn {:ok, line} -> line end)

      {:ok, signing_string}
    else
      {:error, :missing_headers, missing_headers}
    end
  end

  defp get_header_value(conn, header_name) do
    case header_name do
      "(request-target)" ->
        method = conn.method |> String.downcase()
        path = conn.request_path
        query = if conn.query_string != "", do: "?#{conn.query_string}", else: ""
        {:ok, "#{method} #{path}#{query}"}

      "(created)" ->
        # Optional timestamp - return empty if not present
        {:ok, ""}

      "(expires)" ->
        # Optional timestamp - return empty if not present
        {:ok, ""}

      "host" ->
        # Host header - use conn.host if header not present
        case get_req_header(conn, "host") do
          [value | _] -> {:ok, value}
          [] -> {:ok, conn.host}
        end

      _ ->
        case get_req_header(conn, header_name) do
          [value | _] -> {:ok, value}
          [] -> {:error, :missing}
        end
    end
  end
end
