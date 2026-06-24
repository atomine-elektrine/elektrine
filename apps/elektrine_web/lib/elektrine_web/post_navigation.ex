defmodule ElektrineWeb.PostNavigation do
  @moduledoc false

  alias ElektrineWeb.SafeLiveNavigation

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
    SafeLiveNavigation.navigate(socket, path, invalid_message: "Invalid external URL")
  end
end
