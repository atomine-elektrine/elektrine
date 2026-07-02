defmodule Elektrine.Accounts.ClientAppSettings do
  @moduledoc """
  Per-user settings persisted by API clients.
  """

  alias Elektrine.Accounts.ClientAppSetting
  alias Elektrine.Repo

  def get_settings(user_id, app) when is_integer(user_id) and is_binary(app) do
    app = ClientAppSetting.normalize_app(app)

    case Repo.get_by(ClientAppSetting, user_id: user_id, app: app) do
      %ClientAppSetting{settings: settings} when is_map(settings) -> settings
      _ -> %{}
    end
  end

  def update_settings(user_id, app, patch)
      when is_integer(user_id) and is_binary(app) and is_map(patch) do
    app = ClientAppSetting.normalize_app(app)
    existing = Repo.get_by(ClientAppSetting, user_id: user_id, app: app)
    current = settings_from(existing)
    merged = deep_merge_delete(current, patch)

    attrs = %{user_id: user_id, app: app, settings: merged}

    case existing do
      nil ->
        %ClientAppSetting{}
        |> ClientAppSetting.changeset(attrs)
        |> Repo.insert()
        |> unwrap_settings()

      %ClientAppSetting{} = setting ->
        setting
        |> ClientAppSetting.changeset(attrs)
        |> Repo.update()
        |> unwrap_settings()
    end
  end

  def update_settings(_user_id, _app, _patch), do: {:error, :invalid_settings}

  defp settings_from(%ClientAppSetting{settings: settings}) when is_map(settings), do: settings
  defp settings_from(_), do: %{}

  defp unwrap_settings({:ok, %ClientAppSetting{settings: settings}}), do: {:ok, settings}
  defp unwrap_settings(error), do: error

  defp deep_merge_delete(current, patch) do
    Enum.reduce(patch, current, fn
      {key, nil}, acc ->
        Map.delete(acc, key)

      {key, value}, acc when is_map(value) ->
        case Map.get(acc, key) do
          existing when is_map(existing) -> Map.put(acc, key, deep_merge_delete(existing, value))
          _ -> Map.put(acc, key, deep_merge_delete(%{}, value))
        end

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end
end
