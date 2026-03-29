defmodule ElektrineReleaseBuilder.ModuleSelection do
  @known_modules [:chat, :social, :email, :vault, :vpn, :dns]
  @module_order @known_modules |> Enum.with_index() |> Map.new()
  @core_apps [:elektrine, :elektrine_web]
  @module_apps %{
    chat: :elektrine_chat,
    social: :elektrine_social,
    email: :elektrine_email,
    vault: :elektrine_password_manager,
    vpn: :elektrine_vpn,
    dns: :elektrine_dns
  }

  def selected_modules(value \\ requested_module_value()) do
    normalize_modules(value)
  end

  def selected_apps(value \\ requested_module_value()) do
    @core_apps ++ Enum.map(selected_modules(value), &Map.fetch!(@module_apps, &1))
  end

  def build_slug(value \\ requested_module_value()) do
    case selected_modules(value) do
      [] ->
        "none"

      modules when modules == @known_modules ->
        "all"

      modules ->
        Enum.join(modules, "-")
    end
  end

  def normalize_modules(nil), do: @known_modules
  def normalize_modules(""), do: @known_modules
  def normalize_modules(:all), do: @known_modules
  def normalize_modules("all"), do: @known_modules
  def normalize_modules("*"), do: @known_modules
  def normalize_modules(:none), do: []
  def normalize_modules("none"), do: []

  def normalize_modules(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> normalize_modules()
  end

  def normalize_modules(value) when is_list(value) do
    value
    |> Enum.map(&normalize_module/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&Map.fetch!(@module_order, &1))
  end

  def normalize_modules(_value), do: @known_modules

  defp requested_module_value do
    System.get_env("ELEKTRINE_RELEASE_MODULES") || System.get_env("ELEKTRINE_ENABLED_MODULES")
  end

  defp normalize_module(value) when value in @known_modules, do: value

  defp normalize_module(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "chat" -> :chat
      "social" -> :social
      "email" -> :email
      "vault" -> :vault
      "password_manager" -> :vault
      "password-manager" -> :vault
      "vpn" -> :vpn
      "dns" -> :dns
      _ -> nil
    end
  end

  defp normalize_module(_value), do: nil
end
