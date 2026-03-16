defmodule ElektrineWeb.ExternalInteractionController do
  use ElektrineSocialWeb, :controller

  alias Elektrine.ActorPaths

  @community_prefixes ["c", "m"]
  @user_prefixes ["u", "users"]

  def show(conn, %{"uri" => uri}) when is_binary(uri) do
    uri = String.trim(uri)

    conn
    |> redirect(to: resolve_target(uri))
  end

  def show(conn, %{"url" => url}) when is_binary(url), do: show(conn, %{"uri" => url})

  def show(conn, _params) do
    conn
    |> put_flash(:error, "Missing interaction target")
    |> redirect(to: ~p"/")
  end

  defp resolve_target(""), do: ~p"/"

  defp resolve_target(uri) do
    case parse_acct_uri(uri) do
      {:ok, handle} ->
        remote_profile_path(handle)

      :error ->
        case parse_http_actor_uri(uri) do
          {:ok, handle} -> remote_profile_path(handle)
          :error -> remote_post_path(uri)
        end
    end
  end

  defp parse_acct_uri("acct:" <> acct) do
    case String.split(acct, "@", parts: 2) do
      [local, domain] when local != "" and domain != "" ->
        {:ok, "#{local}@#{domain}"}

      _ ->
        :error
    end
  end

  defp parse_acct_uri(_), do: :error

  defp parse_http_actor_uri(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host, path: path}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        actor_handle_from_segments(path_segments(path), host)

      _ ->
        :error
    end
  end

  defp actor_handle_from_segments([prefix, name], host) when prefix in @community_prefixes do
    with {:ok, community_name} <- decode_segment(name) do
      {:ok, "!#{community_name}@#{host}"}
    end
  end

  defp actor_handle_from_segments([prefix, name], host) when prefix in @user_prefixes do
    with {:ok, username} <- decode_segment(name) do
      {:ok, "#{username}@#{host}"}
    end
  end

  defp actor_handle_from_segments([segment], host) do
    with true <- String.starts_with?(segment, "@"),
         {:ok, username} <- decode_segment(String.trim_leading(segment, "@")) do
      {:ok, "#{username}@#{host}"}
    else
      _ -> :error
    end
  end

  defp actor_handle_from_segments(_, _), do: :error

  defp path_segments(nil), do: []
  defp path_segments(path), do: String.split(path, "/", trim: true)

  defp decode_segment(segment) when is_binary(segment) do
    decoded = segment |> URI.decode() |> String.trim()

    if decoded == "" do
      :error
    else
      {:ok, decoded}
    end
  end

  defp remote_profile_path(handle) do
    ActorPaths.profile_path(handle) || "/remote/#{URI.encode_www_form(handle)}"
  end

  defp remote_post_path(uri), do: "/remote/post/#{URI.encode_www_form(uri)}"
end
