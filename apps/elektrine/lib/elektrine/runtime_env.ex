defmodule Elektrine.RuntimeEnv do
  @moduledoc false

  @type env_map :: %{optional(String.t()) => String.t()}

  def environment do
    Application.get_env(:elektrine, :environment, :dev)
  end

  def prod? do
    environment() == :prod
  end

  def dev_or_test? do
    environment() in [:dev, :test]
  end

  def enforce_https? do
    app_config(:enforce_https, false)
  end

  def app_config(key, default \\ nil) when is_atom(key) do
    Application.get_env(:elektrine, key, default)
  end

  def module_config(module, default \\ nil) when is_atom(module) do
    Application.get_env(:elektrine, module, default)
  end

  def present(name, env \\ System.get_env()) when is_binary(name) and is_map(env) do
    case Map.get(env, name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  def first_present(names, env \\ System.get_env()) when is_list(names) and is_map(env) do
    Enum.find_value(names, &present(&1, env))
  end

  def optional_boolean(name, env \\ System.get_env()) when is_binary(name) and is_map(env) do
    case present(name, env) do
      nil -> nil
      value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
      value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] -> false
      _ -> nil
    end
  end

  def truthy?(name, env \\ System.get_env()) when is_binary(name) and is_map(env) do
    optional_boolean(name, env) == true
  end
end
