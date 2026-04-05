defmodule ElektrineChatWeb.ChatLive.HandleFormatter do
  @moduledoc false

  alias Elektrine.Messaging.Federation

  def at_handle(user), do: "@" <> handle(user)

  def handle(%Ecto.Association.NotLoaded{}), do: unknown_handle()
  def handle(nil), do: unknown_handle()

  def handle(user) when is_map(user) do
    identifier =
      first_present([
        map_get(user, :remote_handle),
        map_get(user, :handle),
        map_get(user, :username)
      ])

    fallback_domain =
      first_present([
        map_get(user, :domain),
        map_get(user, :origin_domain)
      ])

    case identifier do
      nil -> unknown_handle()
      value -> normalize_handle(value, fallback_domain)
    end
  end

  def handle(value) when is_binary(value), do: normalize_handle(value, nil)
  def handle(_), do: unknown_handle()

  def domain(user) do
    case String.split(handle(user), "@", parts: 2) do
      [_local, domain] -> domain
      _ -> local_domain()
    end
  end

  def local_domain do
    case Federation.local_domain() do
      domain when is_binary(domain) ->
        case String.trim(domain) do
          "" -> Elektrine.Domains.default_user_handle_domain()
          value -> String.downcase(value)
        end

      _ ->
        Elektrine.Domains.default_user_handle_domain()
    end
  end

  defp normalize_handle(value, fallback_domain) when is_binary(value) do
    cleaned =
      value
      |> String.trim()
      |> String.trim_leading("@")

    case String.split(cleaned, "@", parts: 2) do
      [local, domain] when local != "" and domain != "" ->
        local <> "@" <> normalize_domain(domain)

      [local] when local != "" ->
        local <> "@" <> normalize_domain(fallback_domain || local_domain())

      _ ->
        unknown_handle()
    end
  end

  defp normalize_handle(_value, fallback_domain),
    do: unknown_handle(fallback_domain || local_domain())

  defp normalize_domain(domain) when is_binary(domain) do
    domain
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
    |> case do
      "" -> local_domain()
      value -> value
    end
  end

  defp normalize_domain(_), do: local_domain()

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end)
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil

  defp unknown_handle(domain \\ local_domain()) do
    "unknown@" <> normalize_domain(domain)
  end
end
