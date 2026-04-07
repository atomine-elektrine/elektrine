defmodule ElektrineWeb.PlatformAccess do
  @moduledoc """
  Web-layer mapping between routes/views and hoster-selectable platform modules.
  """

  alias Elektrine.Platform.Modules

  @optional_route_modules [
    {:email, ElektrineWeb.Routes.Email},
    {:chat, ElektrineWeb.Routes.Chat},
    {:social, ElektrineWeb.Routes.Social},
    {:vault, ElektrineWeb.Routes.Vault},
    {:vpn, ElektrineWeb.Routes.VPN},
    {:dns, ElektrineWeb.Routes.DNS}
  ]

  def required_module_for_path(path) when is_binary(path) do
    Enum.find_value(path_prefixes(), fn {module, prefixes} ->
      if Enum.any?(prefixes, &path_matches?(path, &1)), do: module
    end)
  end

  def required_module_for_path(_path), do: nil

  def accessible_path?(path) do
    case required_module_for_path(path) do
      nil -> true
      module -> Modules.enabled?(module)
    end
  end

  def required_module_for_view(view) do
    Enum.find_value(view_modules(), fn {module, views} ->
      if view in views, do: module
    end)
  end

  def accessible_view?(view) do
    case required_module_for_view(view) do
      nil -> true
      module -> Modules.enabled?(module)
    end
  end

  defp path_matches?(path, prefix) do
    cond do
      path == prefix ->
        true

      String.ends_with?(prefix, "/") ->
        String.starts_with?(path, prefix)

      true ->
        String.starts_with?(path, prefix <> "/")
    end
  end

  defp path_prefixes do
    optional_route_metadata(:path_prefixes)
  end

  defp view_modules do
    Map.new(optional_route_metadata(:view_modules))
  end

  defp optional_route_metadata(function) do
    Enum.flat_map(@optional_route_modules, fn {module_id, route_module} ->
      if Code.ensure_loaded?(route_module) and function_exported?(route_module, function, 0) do
        [{module_id, apply(route_module, function, [])}]
      else
        []
      end
    end)
  end
end
