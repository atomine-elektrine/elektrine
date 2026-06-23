defmodule Elektrine.DomainAccount do
  @moduledoc """
  Public, domain-rooted identity document for portable user accounts.

  A domain account document says "this domain is the user's durable identity;
  this Elektrine deployment is only the current provider for auth, profile,
  federation, and recovery surfaces."
  """

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub
  alias Elektrine.Domains

  @version 1
  @did_context "https://www.w3.org/ns/did/v1"

  @doc """
  Builds the public domain account document for a verified user domain.
  """
  def document(user, domain, opts \\ [])

  def document(%User{} = user, domain, opts) when is_binary(domain) do
    domain = normalize_domain(domain)
    account_base_url = "https://#{domain}"
    provider_base_url = opts[:provider_base_url] || Domains.public_base_url()
    handle = user_handle(user)

    %{
      "version" => @version,
      "id" => account_base_url <> "/",
      "subject" => "domain:#{domain}",
      "domain" => domain,
      "portable" => true,
      "hosted_by" => provider_base_url,
      "user" => user_document(user, handle),
      "profile" => %{
        "url" => account_base_url <> "/",
        "avatar_url" => public_avatar_url(user)
      },
      "auth" => auth_document(provider_base_url, domain),
      "federation" => federation_document(user, domain, account_base_url),
      "email" => email_document(user, domain),
      "per_site_identities" => per_site_identity_document(domain, opts[:per_site_identities]),
      "recovery" => recovery_document(provider_base_url)
    }
    |> prune_nil_values()
  end

  def document(_, _, _), do: nil

  @doc """
  Builds a did:web document for a verified user domain.
  """
  def did_document(user, domain, opts \\ [])

  def did_document(%User{} = user, domain, opts) when is_binary(domain) do
    domain = normalize_domain(domain)
    account_base_url = "https://#{domain}"
    provider_base_url = opts[:provider_base_url] || Domains.public_base_url()
    did = did_for_domain(domain)
    activitypub_actor = ActivityPub.actor_uri(user, account_base_url)

    %{
      "@context" => [@did_context],
      "id" => did,
      "alsoKnownAs" =>
        [
          account_base_url <> "/",
          "acct:#{ActivityPub.actor_identifier(user)}@#{domain}",
          activitypub_actor
        ]
        |> Enum.reject(&is_nil/1),
      "service" => [
        %{
          "id" => did <> "#domain-account",
          "type" => "DomainAccount",
          "serviceEndpoint" => account_base_url <> "/.well-known/domain-account"
        },
        %{
          "id" => did <> "#openid-connect",
          "type" => "OpenIDConnectIssuer",
          "serviceEndpoint" => provider_base_url
        },
        %{
          "id" => did <> "#activitypub",
          "type" => "ActivityPubActor",
          "serviceEndpoint" => activitypub_actor
        },
        %{
          "id" => did <> "#arblarg",
          "type" => "Arblarg",
          "serviceEndpoint" => account_base_url <> "/.well-known/_arblarg"
        }
      ]
    }
  end

  def did_document(_, _, _), do: nil

  @doc """
  Returns the did:web identifier for a domain.
  """
  def did_for_domain(domain) when is_binary(domain) do
    "did:web:" <> (domain |> normalize_domain() |> String.replace(":", "%3A"))
  end

  def did_for_domain(_), do: nil

  @doc """
  The stable subject relying parties should store for domain sign-in.
  """
  def subject(domain) when is_binary(domain), do: "domain:#{normalize_domain(domain)}"
  def subject(_), do: nil

  defp user_document(user, handle) do
    %{
      "handle" => handle,
      "username" => user.username,
      "display_name" => blank_to_nil(user.display_name || user.handle || user.username)
    }
  end

  defp auth_document(provider_base_url, domain) do
    %{
      "subject" => subject(domain),
      "identity_domain" => domain,
      "oidc_issuer" => provider_base_url,
      "oidc_discovery" => provider_base_url <> "/.well-known/openid-configuration",
      "authorization_endpoint" => authorization_endpoint(provider_base_url, domain),
      "authorization_endpoint_base" => provider_base_url <> "/oauth/authorize",
      "token_endpoint" => provider_base_url <> "/oauth/token",
      "userinfo_endpoint" => provider_base_url <> "/oauth/userinfo",
      "jwks_uri" => provider_base_url <> "/oauth/jwks"
    }
  end

  defp authorization_endpoint(provider_base_url, domain) do
    provider_base_url <> "/oauth/authorize?" <> URI.encode_query(%{"identity_domain" => domain})
  end

  defp federation_document(user, domain, account_base_url) do
    actor = ActivityPub.actor_uri(user, account_base_url)

    %{
      "activitypub_actor" => actor,
      "activitypub_webfinger" => "acct:#{ActivityPub.actor_identifier(user)}@#{domain}",
      "webfinger" => account_base_url <> "/.well-known/webfinger",
      "arblarg" => account_base_url <> "/.well-known/_arblarg",
      "atproto_did" => bluesky_did_for_user(user)
    }
    |> prune_nil_values()
  end

  defp email_document(user, domain) do
    %{
      "primary_address" => "#{user.username}@#{domain}",
      "domain" => domain
    }
  end

  defp per_site_identity_document(domain, identities) do
    %{
      "subdomain_template" => "{site}.#{domain}",
      "subject_template" => "domain:{site}.#{domain}",
      "did_template" => "did:web:{site}.#{domain}",
      "email_template" => "{site}@#{domain}",
      "identities" => format_per_site_identities(identities, domain)
    }
  end

  defp format_per_site_identities(identities, domain) when is_list(identities) do
    identities
    |> Enum.filter(&(&1.base_domain == domain))
    |> Enum.map(fn identity ->
      %{
        "site_key" => identity.site_key,
        "domain" => identity.domain,
        "subject" => identity.subject,
        "did" => identity.did,
        "email_alias" => identity.email_alias,
        "display_name" => blank_to_nil(identity.display_name),
        "avatar_url" => blank_to_nil(identity.avatar),
        "claims" => identity.claims || %{},
        "enabled" => identity.enabled
      }
      |> prune_nil_values()
    end)
  end

  defp format_per_site_identities(_, _), do: []

  defp recovery_document(provider_base_url) do
    %{
      "export_available" => true,
      "export_url" => provider_base_url <> "/settings/developer/exports",
      "portable_root" => "dns"
    }
  end

  defp public_avatar_url(%{avatar: avatar}) when is_binary(avatar) and avatar != "" do
    avatar
  end

  defp public_avatar_url(_), do: nil

  defp bluesky_did_for_user(%{bluesky_did: "did:" <> _ = did}), do: String.trim(did)
  defp bluesky_did_for_user(%{bluesky_identifier: "did:" <> _ = did}), do: String.trim(did)
  defp bluesky_did_for_user(_), do: nil

  defp user_handle(%User{handle: handle, username: username}) do
    blank_to_nil(handle) || username
  end

  defp normalize_domain(domain) do
    domain
    |> String.trim()
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil

  defp prune_nil_values(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn
      {key, value} when is_map(value) -> {key, prune_nil_values(value)}
      pair -> pair
    end)
  end
end
