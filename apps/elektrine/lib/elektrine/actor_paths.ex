defmodule Elektrine.ActorPaths do
  @moduledoc false

  alias Elektrine.{Accounts, Domains}

  def profile_path(handle) when is_binary(handle) do
    case parse_handle(handle) do
      {:ok, username, domain} -> profile_path(username, domain)
      :error -> nil
    end
  end

  def profile_path(%{username: username, domain: domain} = actor)
      when is_binary(username) and is_binary(domain) do
    profile_path(prefixed_username(actor), domain)
  end

  def profile_path(username, domain) when is_binary(username) and is_binary(domain) do
    local_profile_path(username, domain) || remote_profile_path(username, domain)
  end

  def profile_path(_, _), do: nil

  def local_profile_path(handle) when is_binary(handle) do
    case parse_handle(handle) do
      {:ok, username, domain} -> local_profile_path(username, domain)
      :error -> nil
    end
  end

  def local_profile_path(%{username: username, domain: domain} = actor)
      when is_binary(username) and is_binary(domain) do
    local_profile_path(prefixed_username(actor), domain)
  end

  def local_profile_path(username, domain) when is_binary(username) and is_binary(domain) do
    clean_username = normalize_username(username)
    clean_domain = normalize_domain(domain)

    cond do
      clean_username == "" or clean_domain == "" ->
        nil

      not Domains.local_profile_domain?(clean_domain) ->
        nil

      String.starts_with?(clean_username, "!") ->
        community_name = String.trim_leading(clean_username, "!")
        "/communities/#{URI.encode_www_form(community_name)}"

      true ->
        local_user_profile_path(clean_username)
    end
  end

  def local_profile_path(_, _), do: nil

  def remote_profile_path(username, domain) when is_binary(username) and is_binary(domain) do
    clean_username = normalize_username(username)
    clean_domain = normalize_domain(domain)

    if clean_username == "" or clean_domain == "" do
      nil
    else
      "/remote/#{clean_username}@#{clean_domain}"
    end
  end

  def remote_profile_path(_, _), do: nil

  defp local_user_profile_path(username) do
    case Accounts.get_user_by_username_or_handle(username) do
      %{handle: handle} when is_binary(handle) and handle != "" ->
        "/#{URI.encode_www_form(handle)}"

      %{username: canonical_username}
      when is_binary(canonical_username) and canonical_username != "" ->
        "/#{URI.encode_www_form(canonical_username)}"

      _ ->
        "/#{URI.encode_www_form(username)}"
    end
  end

  defp parse_handle(handle) do
    cleaned =
      handle
      |> String.trim()
      |> String.trim_leading("@")

    case String.split(cleaned, "@", parts: 2) do
      [username, domain] when username != "" and domain != "" ->
        {:ok, normalize_username(username), normalize_domain(domain)}

      _ ->
        :error
    end
  end

  defp prefixed_username(%{actor_type: "Group", username: username}) when is_binary(username) do
    if String.starts_with?(username, "!"), do: username, else: "!" <> username
  end

  defp prefixed_username(%{username: username}), do: username

  defp normalize_username(username) do
    username
    |> String.trim()
    |> String.trim_leading("@")
  end

  defp normalize_domain(domain) do
    domain
    |> String.trim()
    |> String.downcase()
  end
end
