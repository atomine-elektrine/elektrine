defmodule ElektrineWeb.LinkController do
  use ElektrineWeb, :controller
  alias Elektrine.{Profiles, Repo}
  require Logger

  def click(conn, %{"id" => link_id}) do
    # Validate ID is an integer before querying
    case SafeConvert.parse_id(link_id) do
      {:ok, id} ->
        case Repo.get(Profiles.ProfileLink, id) do
          nil ->
            conn
            |> put_status(:not_found)
            |> put_view(html: ElektrineWeb.ErrorHTML)
            |> render(:"404")

          link ->
            # Validate URL to prevent open redirect attacks
            case validate_external_url(link.url) do
              :ok ->
                # Increment click count
                Profiles.increment_link_clicks(link.id)

                # Redirect to the actual URL
                redirect(conn, external: link.url)

              {:error, reason} ->
                Logger.warning("Blocked redirect to invalid URL: #{link.url} (reason: #{reason})")

                conn
                |> put_status(:bad_request)
                |> put_view(html: ElektrineWeb.ErrorHTML)
                |> render(:"400")
            end
        end

      {:error, _} ->
        # Invalid ID format (not an integer)
        conn
        |> put_status(:not_found)
        |> put_view(html: ElektrineWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  # Validates external URLs to prevent open redirect attacks
  defp validate_external_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and not is_nil(host) ->
        # Block localhost and internal IPs
        cond do
          # Block localhost in various forms
          host in ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"] ->
            {:error, :localhost_redirect}

          # Block local network IPs (10.x.x.x, 192.168.x.x, 172.16-31.x.x)
          String.starts_with?(host, "10.") or
            String.starts_with?(host, "192.168.") or
              String.match?(host, ~r/^172\.(1[6-9]|2[0-9]|3[0-1])\./) ->
            {:error, :local_network_redirect}

          # Block IPv6 localhost and link-local
          String.contains?(host, "::") ->
            {:error, :ipv6_local_redirect}

          true ->
            :ok
        end

      %URI{scheme: scheme} when scheme in ["mailto", "tel"] ->
        # Allow mailto and tel links
        :ok

      _ ->
        {:error, :invalid_url_format}
    end
  end

  defp validate_external_url(_), do: {:error, :invalid_input}
end
