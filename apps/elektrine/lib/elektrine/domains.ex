defmodule Elektrine.Domains do
  @moduledoc """
  Centralized helpers for local app domains.
  """

  alias Elektrine.RuntimeEnv

  @default_primary_domain "example.com"

  @doc """
  Primary email domain (usually the main app domain).
  """
  def primary_email_domain do
    email_config()
    |> Keyword.get(:domain, @default_primary_domain)
    |> normalize_domain(@default_primary_domain)
  end

  @doc """
  Domains considered local mailbox domains.
  """
  def supported_email_domains do
    email_config()
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
    configured_profile_base_domains()
  end

  @doc """
  Configured base domains that can host profile subdomains.
  """
  def configured_profile_base_domains do
    Application.get_env(:elektrine, :profile_base_domains, supported_email_domains())
    |> normalize_domains()
    |> ensure_primary_domain()
  end

  @doc """
  Primary base domain for profile URLs.
  """
  def primary_profile_domain do
    List.first(configured_profile_base_domains()) || primary_email_domain()
  end

  @doc """
  Preferred built-in profile domain for user-facing URLs.

  Falls back to the shortest configured profile base domain so vanity domains like
  `z.org` can be preferred over longer primary domains without changing the
  canonical instance domain.
  """
  def default_profile_domain do
    configured_profile_base_domains()
    |> Enum.sort_by(fn domain -> {String.length(domain), domain} end)
    |> List.first()
    |> case do
      nil -> primary_profile_domain()
      domain -> domain
    end
  end

  @doc """
  Preferred built-in profile URL for a handle.
  """
  def default_profile_url_for_handle(handle) when is_binary(handle) do
    normalized_handle = String.trim(handle)

    if not Elektrine.Strings.present?(normalized_handle) do
      nil
    else
      "https://#{normalized_handle}.#{default_profile_domain()}"
    end
  end

  def default_profile_url_for_handle(_), do: nil

  @doc """
  All built-in profile URLs for a handle across configured profile base domains.
  """
  def profile_urls_for_handle(handle) when is_binary(handle) do
    normalized_handle = String.trim(handle)

    if not Elektrine.Strings.present?(normalized_handle) do
      []
    else
      configured_profile_base_domains()
      |> Enum.map(&"https://#{normalized_handle}.#{&1}")
      |> Enum.uniq()
    end
  end

  def profile_urls_for_handle(_), do: []

  @doc """
  Public HTTPS base URL for the main site.
  """
  def public_base_url do
    "https://" <> primary_profile_domain()
  end

  @doc """
  Public HTTPS base URL for mail-facing services.
  """
  def mail_base_url do
    "https://mail." <> primary_email_domain()
  end

  @doc """
  Infers a local base URL for a domain using the current runtime environment.

  This is used for local federation surfaces where development instances may run
  over HTTP on a non-standard port, while production and public tunnel domains
  should stay on HTTPS without an explicit port suffix.
  """
  def inferred_base_url_for_domain(domain) when is_binary(domain) do
    normalized_domain =
      domain
      |> String.trim()
      |> String.downcase()

    is_tunnel =
      String.contains?(normalized_domain, ".") and
        not String.starts_with?(normalized_domain, "localhost")

    scheme = if runtime_environment() == :prod or is_tunnel, do: "https", else: "http"
    port = System.get_env("PORT") || "4000"

    if scheme == "https" or port in ["80", "443"] or is_tunnel do
      "#{scheme}://#{normalized_domain}"
    else
      "#{scheme}://#{normalized_domain}:#{port}"
    end
  end

  @doc """
  Hostname advertised by SMTP and other mail protocols.
  """
  def mail_hostname do
    primary_email_domain()
  end

  @doc """
  Optional DNS target hostname to show when onboarding custom profile domains.

  Set this to the hostname of your external profile edge, such as a dedicated
  Caddy deployment, when custom domains should not point directly at the main app.
  """
  def profile_custom_domain_edge_target do
    System.get_env("PROFILE_CUSTOM_DOMAIN_EDGE_TARGET")
    |> normalize_domain(default_profile_custom_domain_edge_target())
  end

  @doc """
  Stable hostname target for onboarding custom profile domains.

  Falls back to the primary profile domain when no dedicated edge hostname is
  configured.
  """
  def profile_custom_domain_routing_target do
    profile_custom_domain_edge_target() || primary_profile_domain()
  end

  defp default_profile_custom_domain_edge_target do
    "edge." <> primary_profile_domain()
  end

  defp runtime_environment do
    RuntimeEnv.environment()
  end

  defp email_config do
    RuntimeEnv.app_config(:email, [])
  end

  @doc """
  Optional IPv4 address for custom profile domain onboarding.
  """
  def profile_custom_domain_edge_ipv4 do
    normalize_ip_address(System.get_env("PROFILE_CUSTOM_DOMAIN_EDGE_IPV4"))
  end

  @doc """
  Optional IPv6 address for custom profile domain onboarding.
  """
  def profile_custom_domain_edge_ipv6 do
    normalize_ip_address(System.get_env("PROFILE_CUSTOM_DOMAIN_EDGE_IPV6"))
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

    if not Elektrine.Strings.present?(normalized_username) do
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
    Elektrine.Strings.present?(normalized) and normalized in activitypub_domains()
  end

  def local_activitypub_domain?(_), do: false

  @doc """
  True if the given domain is one of our local built-in profile domains.
  """
  def local_profile_domain?(domain) when is_binary(domain) do
    normalized = normalize_host(domain)

    Elektrine.Strings.present?(normalized) and
      (local_activitypub_domain?(normalized) or
         not is_nil(configured_profile_base_domain_for_host(normalized)))
  end

  def local_profile_domain?(_), do: false

  @doc """
  True if the given host is a root app host (domain or www.domain) for configured profile domains.
  """
  def app_host?(host) when is_binary(host) do
    normalized_host = normalize_host(host)

    case profile_base_domain_for_host(normalized_host) do
      nil -> false
      domain -> normalized_host == domain or normalized_host == "www." <> domain
    end
  end

  def app_host?(_), do: false

  @doc """
  Builds the local profile URL for a handle.

  When the current request host is a verified custom profile domain, the returned URL is the
  bare root domain for that profile.
  """
  def profile_url_for_handle(handle, host \\ nil)

  def profile_url_for_handle(handle, host) when is_binary(handle) do
    clean_handle =
      handle
      |> String.trim()
      |> String.trim_leading("@")

    if not Elektrine.Strings.present?(clean_handle) do
      nil
    else
      case profile_custom_domain_for_host(host) do
        %{domain: domain} ->
          "https://#{domain}"

        _ ->
          base_domain = profile_base_domain_for_host(host) || primary_profile_domain()
          "https://#{URI.encode_www_form(clean_handle)}.#{base_domain}"
      end
    end
  end

  def profile_url_for_handle(_, _), do: nil

  @doc """
  Returns the configured profile base domain for a host.
  Supports both root hosts and handle subdomains.
  """
  def profile_base_domain_for_host(host) when is_binary(host) do
    downcased = normalize_host(host)
    configured_profile_base_domain_for_host(downcased)
  end

  def profile_base_domain_for_host(_), do: nil

  @doc """
  Returns the verified custom profile domain for a host when one exists.
  Supports redirecting `www.` aliases to the root domain.
  """
  def profile_custom_domain_for_host(host) when is_binary(host) do
    normalized_host = normalize_host(host)

    if not Elektrine.Strings.present?(normalized_host) do
      nil
    else
      maybe_profile_custom_domains(:get_verified_custom_domain_for_host, [normalized_host])
    end
  end

  def profile_custom_domain_for_host(_), do: nil

  @doc """
  Main domain URL inferred from the request host.
  Returns an empty string when host is not one of our configured domains.
  """
  def main_domain_url_from_host(host, scheme \\ "https")

  def main_domain_url_from_host(host, scheme) when is_binary(host) and is_binary(scheme) do
    if match?(%{domain: _}, profile_custom_domain_for_host(host)) do
      "#{scheme}://#{primary_profile_domain()}"
    else
      case profile_base_domain_for_host(host) do
        nil -> ""
        domain -> "#{scheme}://#{domain}"
      end
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

  defp configured_profile_base_domain_for_host(host) do
    Enum.find(configured_profile_base_domains(), fn domain ->
      host == domain or host == "www." <> domain or String.ends_with?(host, "." <> domain)
    end)
  end

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

  defp maybe_profile_custom_domains(function_name, args) do
    if Code.ensure_loaded?(Elektrine.Profiles.CustomDomains) and
         function_exported?(Elektrine.Profiles.CustomDomains, function_name, length(args)) do
      apply(Elektrine.Profiles.CustomDomains, function_name, args)
    else
      nil
    end
  rescue
    _ -> nil
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

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.split(":", parts: 2)
    |> List.first()
    |> normalize_domain("")
  end

  defp normalize_ip_address(nil), do: nil

  defp normalize_ip_address(value) when is_binary(value) do
    trimmed = String.trim(value)

    case :inet.parse_address(String.to_charlist(trimmed)) do
      {:ok, _ip} -> trimmed
      _ -> nil
    end
  end
end
