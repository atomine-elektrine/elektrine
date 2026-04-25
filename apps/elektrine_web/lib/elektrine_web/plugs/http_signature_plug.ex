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

  @default_signature_max_age_seconds 300
  @default_signature_clock_skew_seconds 300

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
      {:ok, %{"keyId" => key_id, "headers" => headers_string, "signature" => signature} = params} ->
        verify_with_key(conn, key_id, headers_string, signature, params)

      {:error, reason} ->
        Logger.debug("Failed to parse signature header: #{inspect(reason)}")

        conn
        |> assign(:valid_signature, false)
        |> assign(:signature_error, reason)
    end
  end

  defp verify_with_key(conn, key_id, headers_string, signature, signature_params) do
    case SigningKey.get_or_fetch_by_key_id(key_id) do
      {:ok, signing_key} ->
        verify_signature_with_key(conn, signing_key, headers_string, signature, signature_params)

      {:error, reason} ->
        Logger.debug("Failed to fetch signing key #{key_id}: #{inspect(reason)}")

        conn
        |> assign(:valid_signature, false)
        |> assign(:signature_error, {:key_fetch_failed, reason})
    end
  end

  defp verify_signature_with_key(conn, signing_key, headers_string, signature, signature_params) do
    headers_list = parse_signed_headers(headers_string)

    case build_signing_string(conn, headers_list, signature_params) do
      {:ok, signing_string} ->
        if SigningKey.verify(signing_key, signing_string, signature) do
          case validate_signature_constraints(conn, headers_list, signature_params) do
            :ok ->
              # Load the associated user or remote actor
              actor = load_actor_for_key(signing_key)

              conn
              |> assign(:valid_signature, true)
              |> assign(:signature_actor, actor)
              |> assign(:signing_key, signing_key)

            {:error, reason} ->
              conn
              |> assign(:valid_signature, false)
              |> assign(:signature_error, reason)
          end
        else
          Logger.info("Signature verification failed for key #{signing_key.key_id}")

          # Try refreshing the key and verify again
          retry_with_refreshed_key(conn, signing_key, headers_string, signature, signature_params)
        end

      {:error, :missing_headers, missing} ->
        Logger.warning("Missing headers for signature verification: #{inspect(missing)}")

        conn
        |> assign(:valid_signature, false)
        |> assign(:signature_error, {:missing_headers, missing})
    end
  end

  defp retry_with_refreshed_key(conn, signing_key, headers_string, signature, signature_params) do
    case SigningKey.refresh_by_key_id(signing_key.key_id) do
      {:ok, refreshed_key} ->
        headers_list = parse_signed_headers(headers_string)

        case build_signing_string(conn, headers_list, signature_params) do
          {:ok, signing_string} ->
            if SigningKey.verify(refreshed_key, signing_string, signature) do
              case validate_signature_constraints(conn, headers_list, signature_params) do
                :ok ->
                  actor = load_actor_for_key(refreshed_key)

                  conn
                  |> assign(:valid_signature, true)
                  |> assign(:signature_actor, actor)
                  |> assign(:signing_key, refreshed_key)

                {:error, reason} ->
                  conn
                  |> assign(:valid_signature, false)
                  |> assign(:signature_error, reason)
              end
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

  defp parse_signed_headers(headers_string) do
    headers_string
    |> String.split(" ", trim: true)
    |> Enum.map(&String.downcase/1)
  end

  defp parse_signature_header(header) do
    parts = extract_signature_params(header)

    required_keys = ["keyId", "headers", "signature"]

    if Enum.all?(required_keys, &Map.has_key?(parts, &1)) do
      {:ok, parts}
    else
      {:error, :invalid_signature_header}
    end
  end

  defp extract_signature_params(header) do
    Regex.scan(~r/([A-Za-z][A-Za-z0-9_-]*)=(?:"([^"]*)"|([^,\s]+))/, header)
    |> Enum.reduce(%{}, fn
      [_, key, quoted], acc ->
        Map.put(acc, key, quoted)

      [_, key, quoted, unquoted], acc ->
        value =
          case quoted do
            "" -> String.trim(unquoted)
            _ -> quoted
          end

        Map.put(acc, key, value)
    end)
  end

  defp build_signing_string(conn, headers_list, signature_params) do
    results =
      Enum.map(headers_list, fn header_name ->
        case get_header_value(conn, header_name, signature_params) do
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

  defp get_header_value(conn, header_name, signature_params) do
    case header_name do
      "(request-target)" ->
        method = conn.method |> String.downcase()
        path = conn.request_path
        query = if conn.query_string != "", do: "?#{conn.query_string}", else: ""
        {:ok, "#{method} #{path}#{query}"}

      "(created)" ->
        signature_param_value(signature_params, "created")

      "(expires)" ->
        signature_param_value(signature_params, "expires")

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

  defp signature_param_value(signature_params, key) do
    case Map.get(signature_params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing}
    end
  end

  defp validate_signature_constraints(conn, headers_list, signature_params) do
    with :ok <- validate_signature_timing(conn, headers_list, signature_params) do
      validate_request_digest(conn, headers_list)
    end
  end

  defp validate_signature_timing(conn, headers_list, signature_params) do
    cond do
      "(created)" in headers_list or "(expires)" in headers_list ->
        validate_created_expires(signature_params)

      "date" in headers_list ->
        validate_date_header(conn)

      true ->
        {:error, :missing_signature_timestamp}
    end
  end

  defp validate_created_expires(signature_params) do
    now = DateTime.utc_now()
    max_age_seconds = signature_max_age_seconds()
    clock_skew_seconds = signature_clock_skew_seconds()

    with {:ok, created_at} <- parse_optional_unix_timestamp(signature_params, "created"),
         {:ok, expires_at} <- parse_optional_unix_timestamp(signature_params, "expires"),
         :ok <- validate_created_timestamp(now, created_at, max_age_seconds, clock_skew_seconds),
         :ok <- validate_expires_timestamp(now, expires_at, clock_skew_seconds) do
      validate_created_before_expires(created_at, expires_at)
    end
  end

  defp validate_date_header(conn) do
    now = DateTime.utc_now()
    max_age_seconds = signature_max_age_seconds()
    clock_skew_seconds = signature_clock_skew_seconds()

    case get_req_header(conn, "date") do
      [date_header | _] ->
        with {:ok, date_time} <- parse_http_date(date_header),
             diff_seconds <- DateTime.diff(now, date_time, :second),
             true <- diff_seconds <= max_age_seconds,
             true <- diff_seconds >= -clock_skew_seconds do
          :ok
        else
          false ->
            {:error, :stale_signature}

          {:error, _reason} ->
            {:error, :invalid_signature_date}
        end

      [] ->
        {:error, :missing_signature_timestamp}
    end
  end

  defp validate_created_timestamp(_now, nil, _max_age_seconds, _clock_skew_seconds), do: :ok

  defp validate_created_timestamp(now, created_at, max_age_seconds, clock_skew_seconds) do
    cond do
      DateTime.diff(created_at, now, :second) > clock_skew_seconds ->
        {:error, :signature_not_yet_valid}

      DateTime.diff(now, created_at, :second) > max_age_seconds ->
        {:error, :stale_signature}

      true ->
        :ok
    end
  end

  defp validate_expires_timestamp(_now, nil, _clock_skew_seconds), do: :ok

  defp validate_expires_timestamp(now, expires_at, clock_skew_seconds) do
    if DateTime.diff(now, expires_at, :second) > clock_skew_seconds do
      {:error, :signature_expired}
    else
      :ok
    end
  end

  defp validate_created_before_expires(nil, _expires_at), do: :ok
  defp validate_created_before_expires(_created_at, nil), do: :ok

  defp validate_created_before_expires(created_at, expires_at) do
    if DateTime.compare(created_at, expires_at) == :gt do
      {:error, :invalid_signature_window}
    else
      :ok
    end
  end

  defp parse_optional_unix_timestamp(signature_params, key) do
    case Map.get(signature_params, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        parse_unix_timestamp(value)

      value when is_integer(value) ->
        DateTime.from_unix(value)

      _ ->
        {:error, :invalid_signature_timestamp}
    end
  end

  defp parse_unix_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {unix_seconds, ""} -> DateTime.from_unix(unix_seconds)
      _ -> {:error, :invalid_signature_timestamp}
    end
  end

  defp parse_http_date(value) when is_binary(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      {{year, month, day}, {hour, minute, second}} ->
        NaiveDateTime.new(year, month, day, hour, minute, second)
        |> case do
          {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :invalid_signature_date}
    end
  rescue
    _ -> {:error, :invalid_signature_date}
  end

  defp validate_request_digest(conn, headers_list) do
    if request_body_expected?(conn) or "digest" in headers_list do
      if "digest" in headers_list do
        validate_digest_header(conn)
      else
        {:error, :missing_digest_in_signature}
      end
    else
      :ok
    end
  end

  defp request_body_expected?(%Plug.Conn{method: method}) do
    method in ["POST", "PUT", "PATCH"]
  end

  defp validate_digest_header(conn) do
    case get_req_header(conn, "digest") do
      [digest_header | _] ->
        with {:ok, expected_digest} <- extract_sha256_digest(digest_header),
             {:ok, raw_body} <- raw_body(conn) do
          actual_digest = Base.encode64(:crypto.hash(:sha256, raw_body))

          if Plug.Crypto.secure_compare(expected_digest, actual_digest) do
            :ok
          else
            {:error, :digest_mismatch}
          end
        end

      [] ->
        {:error, :missing_digest_header}
    end
  end

  defp extract_sha256_digest(header_value) when is_binary(header_value) do
    header_value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn entry ->
      case String.split(entry, "=", parts: 2) do
        [algorithm, value] ->
          if String.upcase(String.trim(algorithm)) == "SHA-256" do
            {:ok, String.trim(value)}
          else
            nil
          end

        _ ->
          nil
      end
    end)
    |> case do
      {:ok, digest} when digest != "" -> {:ok, digest}
      _ -> {:error, :unsupported_digest_algorithm}
    end
  end

  defp raw_body(conn) do
    case conn.assigns[:raw_body] || conn.private[:cached_body] do
      body when is_binary(body) -> {:ok, body}
      _ -> {:error, :missing_raw_body}
    end
  end

  defp signature_max_age_seconds do
    Application.get_env(:elektrine, :activitypub, [])
    |> Keyword.get(:signature_max_age_seconds, @default_signature_max_age_seconds)
  end

  defp signature_clock_skew_seconds do
    Application.get_env(:elektrine, :activitypub, [])
    |> Keyword.get(:signature_clock_skew_seconds, @default_signature_clock_skew_seconds)
  end
end
