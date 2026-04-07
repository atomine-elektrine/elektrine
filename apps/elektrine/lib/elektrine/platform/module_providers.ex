defmodule Elektrine.Platform.ModuleProviders do
  @moduledoc false

  alias Elektrine.Platform.Modules

  def core_children do
    children_for(:core_children)
  end

  def web_children do
    children_for(:web_children)
  end

  def mail_children do
    children_for(:mail_children)
  end

  def optional_delegate(name) when is_atom(name) do
    Enum.find_value(enabled_provider_modules(), fn provider ->
      if function_exported?(provider, :optional_delegate, 1) do
        provider.optional_delegate(name)
      end
    end)
  end

  def send_vpn_quota_notification(kind, args) when is_atom(kind) and is_list(args) do
    Enum.find_value(enabled_provider_modules(), :ok, fn provider ->
      if function_exported?(provider, :send_vpn_quota_notification, 2) do
        provider.send_vpn_quota_notification(kind, args)
      end
    end)
  end

  defp children_for(function_name) do
    Enum.flat_map(enabled_provider_modules(), fn provider ->
      if function_exported?(provider, function_name, 0) do
        provider
        |> apply(function_name, [])
        |> List.wrap()
      else
        []
      end
    end)
  end

  defp enabled_provider_modules do
    Modules.enabled_specs()
    |> Enum.map(&Map.get(&1, :provider))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&Code.ensure_loaded?/1)
  end
end
