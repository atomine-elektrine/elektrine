defmodule ElektrineSocialWeb.ActivityPub.ActorRequest do
  @moduledoc false

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub
  alias Elektrine.Domains

  def base_url_for_conn(conn) do
    request_host = request_host(conn)
    move_from_domain = Domains.activitypub_move_from_domain()
    canonical_domain = ActivityPub.instance_domain()

    cond do
      request_host != "" and
          match?(%{domain: _}, Domains.profile_custom_domain_for_host(request_host)) ->
        ActivityPub.instance_url_for_domain(request_host)

      request_host != "" and
          not is_nil(Domains.built_in_profile_subdomain_identifier(request_host)) ->
        ActivityPub.instance_url_for_domain(request_host)

      request_host != "" and request_host == move_from_domain ->
        ActivityPub.instance_url_for_domain(request_host)

      request_host != "" and request_host == canonical_domain ->
        ActivityPub.instance_url()

      true ->
        ActivityPub.instance_url()
    end
  end

  def opts_for_actor(user, requested_identifier, conn) do
    base_url = base_url_for_conn(conn)
    canonical_base_url = canonical_base_url_for_request(user, conn)
    legacy_base_url = legacy_base_url()
    canonical_actor_uri = ActivityPub.actor_uri(user, canonical_base_url)
    requested_actor_uri = ActivityPub.actor_uri(requested_identifier, base_url)

    if requested_actor_uri != canonical_actor_uri do
      %{
        base_url: base_url,
        actor_identifier: requested_identifier,
        moved_to: canonical_actor_uri
      }
    else
      aliases =
        user
        |> actor_alias_uris(canonical_base_url, legacy_base_url)
        |> append_configured_aliases(user)

      %{
        base_url: base_url,
        also_known_as: aliases,
        moved_to: user.moved_to
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
      |> Map.new()
    end
  end

  defp canonical_base_url_for_request(user, conn) do
    request_host = request_host(conn)

    case Domains.profile_custom_domain_for_host(request_host) do
      %{domain: domain, user_id: user_id} when user_id == user.id ->
        ActivityPub.instance_url_for_domain(domain)

      _ ->
        if built_in_profile_subdomain_for_user?(user, request_host) do
          ActivityPub.instance_url_for_domain(request_host)
        else
          ActivityPub.instance_url()
        end
    end
  end

  defp built_in_profile_subdomain_for_user?(%User{} = user, request_host) do
    identifier = Domains.built_in_profile_subdomain_identifier(request_host)

    not is_nil(identifier) and
      identifier == ActivityPub.actor_identifier(user) and
      User.built_in_subdomain_hosted_by_platform?(user)
  end

  defp built_in_profile_subdomain_for_user?(_, _), do: false

  defp actor_alias_uris(user, canonical_base_url, legacy_base_url) do
    canonical_actor_uri = ActivityPub.actor_uri(user, canonical_base_url)

    [
      username_alias_uri(user, canonical_base_url),
      legacy_actor_uri(user, legacy_base_url),
      legacy_username_alias_uri(user, legacy_base_url)
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == canonical_actor_uri))
    |> Enum.uniq()
  end

  defp append_configured_aliases(aliases, %{also_known_as: configured})
       when is_list(configured) do
    (aliases ++ configured)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  defp append_configured_aliases(aliases, _user), do: aliases

  defp username_alias_uri(user, base_url) do
    canonical_identifier = ActivityPub.actor_identifier(user)

    if canonical_identifier == user.username do
      nil
    else
      ActivityPub.actor_uri_by_username(user, base_url)
    end
  end

  defp legacy_actor_uri(user, legacy_base_url) when is_binary(legacy_base_url) do
    ActivityPub.actor_uri(user, legacy_base_url)
  end

  defp legacy_actor_uri(_user, _legacy_base_url), do: nil

  defp legacy_username_alias_uri(user, legacy_base_url) when is_binary(legacy_base_url) do
    username_alias_uri(user, legacy_base_url)
  end

  defp legacy_username_alias_uri(_user, _legacy_base_url), do: nil

  defp legacy_base_url do
    case Domains.activitypub_move_from_domain() do
      nil -> nil
      domain -> ActivityPub.instance_url_for_domain(domain)
    end
  end

  defp request_host(conn) do
    (conn.host || "")
    |> String.trim()
    |> String.downcase()
    |> String.trim_leading("www.")
  end
end
