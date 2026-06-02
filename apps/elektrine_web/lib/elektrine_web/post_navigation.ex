defmodule ElektrineWeb.PostNavigation do
  @moduledoc false

  import Phoenix.LiveView

  alias Elektrine.Security.SafeExternalURL

  def navigate(socket, ref) do
    case Elektrine.Paths.post_path_or_external(ref) do
      nil ->
        socket

      path ->
        navigate_to_path(socket, path)
    end
  end

  def path(ref), do: Elektrine.Paths.post_path_or_external(ref)

  def external_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        true

      _ ->
        false
    end
  end

  def external_url?(_), do: false

  defp navigate_to_path(socket, path) when is_binary(path) do
    if external_url?(path) do
      case SafeExternalURL.normalize(path) do
        {:ok, safe_url} -> redirect(socket, external: safe_url)
        {:error, _reason} -> put_flash(socket, :error, "Invalid external URL")
      end
    else
      push_navigate(socket, to: path)
    end
  end
end
