defmodule ElektrineWeb.LinkController do
  use ElektrineWeb, :controller
  alias Elektrine.{Profiles, Repo}
  alias Elektrine.Security.SafeExternalURL
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
            case {link_visible?(link), validate_external_url(link.url)} do
              {false, _} ->
                conn
                |> put_status(:not_found)
                |> put_view(html: ElektrineWeb.ErrorHTML)
                |> render(:"404")

              {true, {:ok, safe_url}} ->
                Profiles.increment_link_clicks(link.id)
                redirect(conn, external: safe_url)

              {true, {:error, reason}} ->
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
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        case SafeExternalURL.normalize(url) do
          {:ok, safe_url} -> {:ok, safe_url}
          {:error, reason} -> {:error, reason}
        end

      %URI{scheme: scheme} when scheme in ["mailto", "tel"] ->
        with :ok <- validate_contact_url(scheme, url) do
          {:ok, url}
        end

      _ ->
        {:error, :invalid_url_format}
    end
  end

  defp validate_external_url(_), do: {:error, :invalid_input}

  defp link_visible?(link) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    link.is_active == true &&
      (is_nil(link.active_from) || DateTime.compare(link.active_from, now) != :gt) &&
      (is_nil(link.active_until) || DateTime.compare(link.active_until, now) == :gt)
  end

  defp validate_contact_url(_scheme, url) when is_binary(url) do
    if String.contains?(url, ["\r", "\n", "\0"]) or Regex.match?(~r/[\x00-\x1F\x7F\s]/, url) do
      {:error, :unsafe_contact_url}
    else
      do_validate_contact_url(url)
    end
  end

  defp do_validate_contact_url("mailto:" <> address) do
    if Regex.match?(~r/^[^@<>"']+@[^@<>"']+\.[^@<>"']+$/, address) do
      :ok
    else
      {:error, :invalid_mailto_url}
    end
  end

  defp do_validate_contact_url("tel:" <> phone) do
    if Regex.match?(~r/^\+?[0-9().-]{3,32}$/, phone) do
      :ok
    else
      {:error, :invalid_tel_url}
    end
  end

  defp do_validate_contact_url(_url), do: {:error, :invalid_url_format}
end
