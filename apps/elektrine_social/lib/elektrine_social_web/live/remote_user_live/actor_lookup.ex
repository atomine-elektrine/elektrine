defmodule ElektrineSocialWeb.RemoteUserLive.ActorLookup do
  @moduledoc false

  alias Elektrine.ActivityPub
  alias Elektrine.Paths

  def local_profile_redirect_path(%{"handle" => handle}) when is_binary(handle) do
    Paths.local_profile_path(handle)
  end

  def local_profile_redirect_path(_), do: nil

  def cached_from_params(%{"handle" => handle}) when is_binary(handle) do
    with {:ok, %{username: username, domain: domain}} <- parse_remote_handle(handle),
         %{} = actor <- ActivityPub.get_actor_by_username_and_domain(username, domain) do
      {:ok, actor}
    else
      _ -> :error
    end
  end

  def cached_from_params(_), do: :error

  def resolve(username, domain, acct)
      when is_binary(username) and is_binary(domain) and is_binary(acct) do
    case ActivityPub.get_actor_by_username_and_domain(username, domain) do
      %{} = actor ->
        {:ok, actor}

      nil ->
        case ActivityPub.webfinger_lookup(acct) do
          {:ok, actor_uri} ->
            case ActivityPub.fetch_and_cache_actor(actor_uri, allow_recovery: false) do
              {:ok, actor} -> {:ok, actor}
              error -> error
            end

          error ->
            error
        end
    end
  end

  def parse_remote_handle(handle) when is_binary(handle) do
    cleaned = String.trim(handle)

    case cleaned do
      "" ->
        {:error, :invalid_handle}

      "!" <> rest ->
        build_remote_handle(rest, "!")

      "@" <> rest ->
        build_remote_handle(rest, "")

      _ ->
        build_remote_handle(cleaned, "")
    end
  end

  def parse_remote_handle(_), do: {:error, :invalid_handle}

  defp build_remote_handle(handle, prefix) do
    case String.split(handle, "@", parts: 2) do
      [username, domain] when username != "" and domain != "" ->
        {:ok,
         %{
           username: username,
           domain: domain,
           acct: "#{prefix}#{username}@#{domain}"
         }}

      _ ->
        {:error, :invalid_handle}
    end
  end
end
