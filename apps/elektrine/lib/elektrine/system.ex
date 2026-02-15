defmodule Elektrine.System do
  @moduledoc """
  The System context for managing system-wide configuration.
  """

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
