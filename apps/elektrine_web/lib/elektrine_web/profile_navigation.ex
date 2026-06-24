defmodule ElektrineWeb.ProfileNavigation do
  @moduledoc false

  import Phoenix.LiveView, only: [push_navigate: 2, redirect: 2]

  alias Elektrine.{Accounts, Domains}
  alias Elektrine.Security.SafeExternalURL

  def navigate(socket, params) when is_map(params) do
    params
    |> profile_url()
    |> navigate_to_url(socket)
  end

  def profile_url(%{"user_id" => user_id}) do
    user_id
    |> parse_user_id()
    |> case do
      nil -> nil
      id -> Accounts.get_user!(id)
    end
    |> profile_url_for_user()
  rescue
    _ -> nil
  end

  def profile_url(%{"handle" => handle}), do: profile_url_for_handle(handle)
  def profile_url(%{"username" => username}), do: profile_url_for_handle(username)
  def profile_url(_), do: nil

  defp profile_url_for_user(nil), do: nil

  defp profile_url_for_user(user) do
    Domains.profile_url_for_user(user) || profile_url_for_handle(user.handle || user.username)
  end

  defp profile_url_for_handle(handle) when is_binary(handle) do
    clean_handle = handle |> String.trim() |> String.trim_leading("@")

    if Elektrine.Strings.present?(clean_handle) do
      case Accounts.get_user_by_handle(clean_handle) do
        nil -> Domains.default_profile_url_for_handle(clean_handle) || "/#{clean_handle}"
        user -> profile_url_for_user(user)
      end
    end
  end

  defp profile_url_for_handle(_), do: nil

  defp navigate_to_url(nil, socket), do: {:noreply, socket}

  defp navigate_to_url("http" <> _ = url, socket) do
    case SafeExternalURL.normalize(url) do
      {:ok, safe_url} -> {:noreply, redirect(socket, external: safe_url)}
      {:error, _reason} -> {:noreply, push_navigate(socket, to: "/")}
    end
  end

  defp navigate_to_url(path, socket), do: {:noreply, push_navigate(socket, to: path)}

  defp parse_user_id(value) when is_integer(value), do: value

  defp parse_user_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_user_id(_), do: nil
end
