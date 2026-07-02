defmodule ElektrineSocialWeb.MediaProxyController do
  @moduledoc """
  Controller for the media proxy.

  Handles requests to /media_proxy/{signature}/{encoded_url} and proxies
  the content from the remote server while caching it locally.
  """

  use ElektrineSocialWeb, :controller

  require Logger

  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.MediaProxy
  alias Elektrine.Security.URLValidator

  # Keep proxied media bounded; the current SafeFetch path buffers before sending.
  @max_file_size 10 * 1024 * 1024
  @max_redirects 5

  # Cache control for proxied content
  # 1 year
  @cache_control "public, max-age=31536000"

  @doc """
  Proxies a remote media file.
  """
  def proxy(conn, %{"signature" => signature, "encoded_url" => encoded_url}) do
    encoded = "#{signature}/#{encoded_url}"

    case MediaProxy.decode_url(encoded) do
      {:ok, url} ->
        with :ok <- validate_proxy_url(url),
             false <- MediaProxy.failed?(url),
             false <- MediaProxy.blocklisted?(url) do
          fetch_and_proxy(conn, url, 0)
        else
          true ->
            send_error(conn, 404, "Not found")

          {:error, reason} ->
            Logger.warning("MediaProxy blocked unsafe URL #{inspect(url)}: #{inspect(reason)}")
            send_error(conn, 400, "Invalid proxy URL")
        end

      {:error, _reason} ->
        send_error(conn, 400, "Invalid proxy URL")
    end
  end

  defp fetch_and_proxy(conn, url, redirect_count) do
    headers = [
      {"user-agent", "Elektrine/1.0 MediaProxy (+#{ElektrineWeb.Endpoint.url()})"},
      {"accept", "*/*"}
    ]

    request = Finch.build(:get, url, headers)

    case SafeFetch.request(request, Elektrine.Finch,
           receive_timeout: 30_000,
           pool_timeout: 30_000,
           max_body_bytes: @max_file_size
         ) do
      {:ok, %Finch.Response{status: status, headers: resp_headers, body: body}}
      when status in 200..299 ->
        proxy_response(conn, body, resp_headers, url)

      {:ok, %Finch.Response{status: 301, headers: resp_headers}} ->
        handle_redirect(conn, resp_headers, url, redirect_count)

      {:ok, %Finch.Response{status: 302, headers: resp_headers}} ->
        handle_redirect(conn, resp_headers, url, redirect_count)

      {:ok, %Finch.Response{status: 304}} ->
        send_resp(conn, 304, "")

      {:ok, %Finch.Response{status: status}} ->
        Logger.warning("MediaProxy: Got #{status} for #{redacted_url(url)}")
        MediaProxy.mark_failed(url, {:http_status, status})
        send_error(conn, 502, "Upstream error")

      {:error, :too_large} ->
        MediaProxy.mark_failed(url, :too_large)
        send_error(conn, 413, "File too large")

      {:error, reason} ->
        Logger.warning("MediaProxy: Failed to fetch #{redacted_url(url)}: #{inspect(reason)}")
        MediaProxy.mark_failed(url, reason)
        send_error(conn, 502, "Failed to fetch media")
    end
  end

  defp proxy_response(conn, body, headers, url) do
    # Check file size
    if byte_size(body) > @max_file_size do
      MediaProxy.mark_failed(url, :too_large)
      send_error(conn, 413, "File too large")
    else
      MediaProxy.invalidate(url)

      content_type =
        headers
        |> get_header("content-type")
        |> safe_response_content_type()

      conn
      |> put_resp_header("content-type", content_type)
      |> put_resp_header("cache-control", @cache_control)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> maybe_put_content_disposition(content_type)
      |> send_resp(200, body)
    end
  end

  defp handle_redirect(conn, _headers, _original_url, redirect_count)
       when redirect_count >= @max_redirects do
    send_error(conn, 502, "Too many redirects")
  end

  defp handle_redirect(conn, headers, original_url, redirect_count) do
    with location when is_binary(location) <- get_header(headers, "location"),
         redirect_url <- URI.merge(original_url, location) |> to_string(),
         :ok <- validate_proxy_url(redirect_url),
         false <- MediaProxy.blocklisted?(redirect_url) do
      fetch_and_proxy(conn, redirect_url, redirect_count + 1)
    else
      nil ->
        send_error(conn, 502, "Invalid redirect")

      true ->
        send_error(conn, 404, "Not found")

      {:error, reason} ->
        Logger.warning(
          "MediaProxy blocked unsafe redirect target from #{inspect(original_url)}: #{inspect(reason)}"
        )

        send_error(conn, 400, "Invalid redirect target")
    end
  end

  @doc false
  def inline_safe_content_type?(content_type) when is_binary(content_type) do
    normalized = normalize_media_type(content_type)

    cond do
      not safe_media_type?(normalized) -> false
      normalized in ["image/svg+xml", "image/svg+xml-compressed"] -> false
      normalized in ["image/jpeg", "image/jpg", "image/png", "image/gif", "image/webp"] -> true
      normalized == "image/avif" -> true
      String.starts_with?(normalized, ["video/", "audio/"]) -> true
      normalized == "text/plain" -> true
      true -> false
    end
  end

  def inline_safe_content_type?(_content_type), do: false

  defp safe_response_content_type(content_type) do
    normalized = normalize_media_type(content_type)

    if safe_media_type?(normalized), do: normalized, else: "application/octet-stream"
  end

  defp normalize_media_type(content_type) do
    content_type
    |> to_string()
    |> String.downcase()
    |> String.split(";", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
  end

  defp safe_media_type?(content_type) do
    Regex.match?(~r/^[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*$/, content_type)
  end

  defp maybe_put_content_disposition(conn, content_type) do
    if inline_safe_content_type?(content_type) do
      conn
    else
      put_resp_header(conn, "content-disposition", "attachment")
    end
  end

  defp get_header(headers, name) do
    name = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(k) == name, do: v
    end)
  end

  defp send_error(conn, status, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  defp validate_proxy_url(url) when is_binary(url) do
    URLValidator.validate(url)
  end

  defp redacted_url(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.put(:query, nil)
    |> Map.put(:userinfo, nil)
    |> URI.to_string()
  rescue
    _ -> "[invalid-url]"
  end
end
