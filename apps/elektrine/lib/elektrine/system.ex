defmodule Elektrine.System do
  @moduledoc """
  The System context for managing system-wide configuration.
  """

  @self_service_invite_min_trust_level_default 1
  @module_access_defaults %{
    portal: 0,
    chat: 0,
    timeline: 0,
    communities: 0,
    gallery: 0,
    lists: 0,
    friends: 0,
    email: 0,
    vault: 0,
    dns: 0,
    storage: 0,
    notes: 0,
    drive: 0,
    vpn: 0
  }

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.System.Config

  @doc """
  Gets a configuration value by key.
  Returns the parsed value based on the type.
  """
  def get_config(key, default \\ nil) do
    case Repo.get_by(Config, key: key) do
      nil -> default
      config -> Config.parse_value(config)
    end
  end

  @doc """
  Sets a configuration value.
  """
  def set_config(key, value, type \\ "string", description \\ nil) do
    config = Repo.get_by(Config, key: key) || %Config{key: key}

    attrs = %{
      value: to_string(value),
      type: type,
      description: description || config.description
    }

    config
    |> Config.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Checks if invite codes are enabled for registration.
  """
  def invite_codes_enabled? do
    get_config("invite_codes_enabled", true)
  end

  @doc """
  Enables or disables the invite code system.
  """
  def set_invite_codes_enabled(enabled) when is_boolean(enabled) do
    set_config(
      "invite_codes_enabled",
      enabled,
      "boolean",
      "Enable or disable the invite code system for user registration"
    )
  end

  @doc """
  Returns the minimum trust level required for user-created invite codes.
  """
  def self_service_invite_min_trust_level do
    case get_config(
           "self_service_invite_min_trust_level",
           @self_service_invite_min_trust_level_default
         ) do
      level when is_integer(level) and level in 0..4 -> level
      _other -> @self_service_invite_min_trust_level_default
    end
  end

  @doc """
  Sets the minimum trust level required for user-created invite codes.
  """
  def set_self_service_invite_min_trust_level(level) when is_integer(level) and level in 0..4 do
    set_config(
      "self_service_invite_min_trust_level",
      level,
      "integer",
      "Minimum trust level required for self-service invite code creation"
    )
  end

  def set_self_service_invite_min_trust_level(_level), do: {:error, :invalid_level}

  @doc """
  Returns the admin-managed minimum trust levels for user-facing modules.
  """
  def module_access_rules do
    @module_access_defaults
    |> Enum.map(fn {module, default_level} ->
      %{
        module: module,
        label: module_access_label(module),
        min_trust_level: module_min_trust_level(module, default_level)
      }
    end)
    |> Enum.sort_by(& &1.label)
  end

  def module_min_trust_level(module, default \\ nil) do
    module = normalize_module(module)
    default = default || Map.get(@module_access_defaults, module, 0)

    case get_config(module_access_key(module), default) do
      level when is_integer(level) and level in 0..4 -> level
      _other -> default
    end
  end

  def set_module_min_trust_level(module, level) when is_integer(level) and level in 0..4 do
    module = normalize_module(module)

    if Map.has_key?(@module_access_defaults, module) do
      set_config(
        module_access_key(module),
        level,
        "integer",
        "Minimum trust level required to access #{module_access_label(module)}"
      )
    else
      {:error, :unknown_module}
    end
  end

  def set_module_min_trust_level(_module, _level), do: {:error, :invalid_level}

  def user_can_access_module?(%{is_admin: true}, _module), do: true

  def user_can_access_module?(nil, module), do: module_min_trust_level(module) == 0

  def user_can_access_module?(%{trust_level: trust_level}, module) when is_integer(trust_level),
    do: trust_level >= module_min_trust_level(module)

  def user_can_access_module?(_user, _module), do: false

  defp module_access_key(module), do: "module_access_min_trust_level_#{module}"

  defp normalize_module(module) when is_atom(module), do: module

  defp normalize_module(module) when is_binary(module) do
    module = String.trim(module)

    Enum.find(Map.keys(@module_access_defaults), module, &(to_string(&1) == module))
  end

  defp normalize_module(module), do: module

  defp module_access_label(:dns), do: "DNS"
  defp module_access_label(:vpn), do: "VPN"
  defp module_access_label(:email), do: "Email"
  defp module_access_label(:vault), do: "Vault"
  defp module_access_label(:drive), do: "Drive"
  defp module_access_label(:notes), do: "Notes"
  defp module_access_label(:storage), do: "Storage"
  defp module_access_label(:portal), do: "Portal"
  defp module_access_label(:chat), do: "Chat"
  defp module_access_label(:timeline), do: "Timeline"
  defp module_access_label(:communities), do: "Communities"
  defp module_access_label(:gallery), do: "Gallery"
  defp module_access_label(:lists), do: "Lists"
  defp module_access_label(:friends), do: "Friends"
  defp module_access_label(module), do: module |> to_string() |> String.capitalize()

  @doc """
  Gets all configuration entries.
  """
  def list_configs do
    Config
    |> order_by(asc: :key)
    |> Repo.all()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking config changes.
  """
  def change_config(%Config{} = config, attrs \\ %{}) do
    Config.changeset(config, attrs)
  end
end
