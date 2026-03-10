defmodule Elektrine.Domains do
  @moduledoc """
  Centralized helpers for local app domains.
  """

  @default_primary_domain "elektrine.com"

  @doc """
  Primary email domain (usually the main app domain).
  """
  def primary_email_domain do
    Application.get_env(:elektrine, :email, [])
    |> Keyword.get(:domain, @default_primary_domain)
    |> normalize_domain(@default_primary_domain)
  end

  @doc """
  Domains considered local mailbox domains.
  """
  def supported_email_domains do
    Application.get_env(:elektrine, :email, [])
    |> Keyword.get(:supported_domains, [primary_email_domain()])
    |> normalize_domains()
    |> ensure_primary_domain()
  end

  @doc """
  All receiving email domains, including verified user custom domains.
  """
  def receiving_email_domains do
    (supported_email_domains() ++ verified_custom_email_domains())
    |> normalize_domains()
    |> ensure_primary_domain()
  end

  @doc """
  Email domains available to a specific user for sending and main address variants.
  """
  def available_email_domains_for_user(user_or_user_id) do
    (supported_email_domains() ++ verified_custom_email_domains_for_user(user_or_user_id))
    |> normalize_domains()
    |> ensure_primary_domain()
  end

  @doc """
  Base domains that can host profile subdomains.
  """
  def profile_base_domains do
    Application.get_env(:elektrine, :profile_base_domains, supported_email_domains())
    |> normalize_domains()
    |> ensure_primary_domain()
  end

  @doc """
  Primary base domain for profile URLs.
  """
  def primary_profile_domain do
    List.first(profile_base_domains()) || primary_email_domain()
  end

  @doc """
  Main app hosts (root + www for each configured profile base domain).
  """
  def app_hosts do
    profile_base_domains()
    |> Enum.flat_map(&[&1, "www." <> &1])
    |> Enum.uniq()
  end

  @doc """
  Local passkey domains, including localhost for development.
  """
  def local_passkey_domains do
    (profile_base_domains() ++ ["localhost"])
    |> normalize_domains()
    |> Enum.uniq()
  end

  @doc """
  True if the given domain is one of our local mailbox domains.
  """
  def local_email_domain?(domain) when is_binary(domain) do
    String.downcase(domain) in supported_email_domains()
  end

  def local_email_domain?(_), do: false

  @doc """
  True if the given domain receives mail locally, including verified custom domains.
  """
  def receiving_email_domain?(domain) when is_binary(domain) do
    String.downcase(domain) in receiving_email_domains()
  end

  def receiving_email_domain?(_), do: false

  @doc """
  Builds all local email addresses for a username across supported domains.
  """
  def local_addresses_for_username(username) when is_binary(username) do
    normalized_username = String.trim(username)

    if normalized_username == "" do
      []
    else
      supported_email_domains()
      |> Enum.map(&"#{normalized_username}@#{&1}")
    end
  end

  def local_addresses_for_username(_), do: []

  @doc """
  Builds all available main addresses for a user across system and verified custom domains.
  """
  def email_addresses_for_user(%{id: user_id, username: username})
      when is_integer(user_id) and is_binary(username) do
    available_email_domains_for_user(user_id)
    |> Enum.map(&"#{String.trim(username)}@#{&1}")
  end

  def email_addresses_for_user(_), do: []

  @doc """
  Builds all local email address variants for a given local email address.
  """
  def local_address_variants(email_address) when is_binary(email_address) do
    case String.split(String.trim(String.downcase(email_address)), "@", parts: 2) do
      [username, domain] when username != "" ->
        if local_email_domain?(domain) do
          local_addresses_for_username(username)
        else
          []
        end

      _ ->
        []
    end
  end

  def local_address_variants(_), do: []

  @doc """
  Returns alternative local-domain variants for a local email address.
  """
  def alternate_local_addresses(email_address) when is_binary(email_address) do
    downcased = String.downcase(String.trim(email_address))
    local_address_variants(downcased) |> Enum.reject(&(&1 == downcased))
  end

  def alternate_local_addresses(_), do: []

  @doc """
  Reserved local-part names that must not be user-created aliases/mailboxes.
  """
  def reserved_local_parts do
    [
      "admin",
      "administrator",
      "support",
      "noreply",
      "no-reply",
      "postmaster",
      "hostmaster",
      "webmaster",
      "abuse",
      "security",
      "help",
      "info",
      "contact",
      "mail",
      "email",
      "inbox",
      "outbox",
      "followers",
      "following",
      "actor",
      "users",
      "activities",
      "relay",
      "ap"
    ]
  end

  @doc """
  Reserved full addresses across all supported local domains.
  """
  def reserved_addresses do
    for local_part <- reserved_local_parts(), domain <- supported_email_domains() do
      "#{local_part}@#{domain}"
    end
  end

  @doc """
  Default domain for local handle display and contact links.
  """
  def default_user_handle_domain do
    List.first(supported_email_domains()) || primary_email_domain()
  end

  @doc """
  Instance domain for federation documents and actor URLs.
  """
  def instance_domain do
    configured = System.get_env("INSTANCE_DOMAIN")
    fallback = primary_profile_domain()
    normalize_domain(configured || fallback, fallback)
  end

  @doc """
  Optional legacy ActivityPub domain to migrate from.
  """
  def activitypub_move_from_domain do
    configured = System.get_env("ACTIVITYPUB_MOVE_FROM_DOMAIN")
    canonical = instance_domain()
    normalized = normalize_domain(configured, nil)

    case normalized do
      nil -> nil
      "" -> nil
      ^canonical -> nil
      value -> value
    end
  end

  @doc """
  True when ActivityPub account migration mode is enabled.
  """
  def activitypub_migration_enabled? do
    not is_nil(activitypub_move_from_domain())
  end

  @doc """
  Domains treated as local for ActivityPub identity/discovery.
  """
  def activitypub_domains do
    ([instance_domain(), activitypub_move_from_domain()] ++
       profile_base_domains() ++ supported_email_domains())
    |> normalize_domains()
    |> Enum.uniq()
  end

  @doc """
  True if the given domain is one of our local ActivityPub domains.
  """
  def local_activitypub_domain?(domain) when is_binary(domain) do
    normalized = normalize_domain(domain, "")
    normalized != "" and normalized in activitypub_domains()
  end

  def local_activitypub_domain?(_), do: false

  @doc """
  Returns the configured profile base domain for a host.
  Supports both root hosts and handle subdomains.
  """
  def profile_base_domain_for_host(host) when is_binary(host) do
    downcased = String.downcase(host)

    Enum.find(profile_base_domains(), fn domain ->
      downcased == domain or downcased == "www." <> domain or
        String.ends_with?(downcased, "." <> domain)
    end)
  end

  def profile_base_domain_for_host(_), do: nil

  @doc """
  Main domain URL inferred from the request host.
  Returns an empty string when host is not one of our configured domains.
  """
  def main_domain_url_from_host(host, scheme \\ "https")

  def main_domain_url_from_host(host, scheme) when is_binary(host) and is_binary(scheme) do
    case profile_base_domain_for_host(host) do
      nil -> ""
      domain -> "#{scheme}://#{domain}"
    end
  end

  def main_domain_url_from_host(_, _), do: ""

  defp verified_custom_email_domains do
    maybe_custom_domains(:verified_domains, [])
  end

  defp verified_custom_email_domains_for_user(%{id: user_id}),
    do: verified_custom_email_domains_for_user(user_id)

  defp verified_custom_email_domains_for_user(user_id) when is_integer(user_id) do
    maybe_custom_domains(:verified_domains_for_user, [user_id])
  end

  defp verified_custom_email_domains_for_user(_), do: []

  defp maybe_custom_domains(function_name, args) do
    if Code.ensure_loaded?(Elektrine.Email.CustomDomains) and
         function_exported?(Elektrine.Email.CustomDomains, function_name, length(args)) do
      apply(Elektrine.Email.CustomDomains, function_name, args)
    else
      []
    end
  rescue
    _ -> []
  end

  defp ensure_primary_domain(domains) do
    primary = primary_email_domain()

    if primary in domains do
      domains
    else
      [primary | domains]
    end
  end

  defp normalize_domains(domains) when is_list(domains) do
    domains
    |> Enum.map(&normalize_domain(&1, nil))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_domains(_), do: []

  defp normalize_domain(nil, fallback), do: fallback

  defp normalize_domain(domain, fallback) when is_binary(domain) do
    domain
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> fallback
      value -> value
    end
  end
end
