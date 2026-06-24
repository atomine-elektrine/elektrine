defmodule Elektrine.AtomineProofBundle do
  @moduledoc """
  Public Atomine proof bundle for a domain-rooted identity.

  The bundle is intentionally claim-oriented rather than score-oriented. It
  gives consumers a signed set of verifiable statements and lets them decide
  which claims matter for their own risk model.
  """

  alias Atomine.Personhood
  alias Elektrine.Accounts.TrustLevel
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub
  alias Elektrine.DomainAccount
  alias Elektrine.Domains
  alias Elektrine.OIDC
  alias Elektrine.Uploads

  @version 1
  @bundle_type "atomine.proof_bundle"
  @signature_typ "atomine-proof-bundle+jwt"

  def document(user, domain, opts \\ [])

  def document(%User{} = user, domain, opts) when is_binary(domain) do
    domain = normalize_domain(domain)
    provider_base_url = opts[:provider_base_url] || Domains.public_base_url()
    account_base_url = "https://#{domain}"
    issued_at = DateTime.utc_now() |> DateTime.truncate(:second)

    payload =
      %{
        "type" => @bundle_type,
        "version" => @version,
        "issuer" => provider_base_url,
        "subject" => DomainAccount.subject(domain),
        "domain" => domain,
        "did" => DomainAccount.did_for_domain(domain),
        "profile" => profile_document(user, domain, account_base_url),
        "federation" => federation_document(user, domain, account_base_url),
        "claims" => claims(user, domain, account_base_url),
        "proofs" => atomine_proofs(user),
        "verification" => %{
          "jwks_uri" => provider_base_url <> "/oauth/jwks",
          "signature_format" => "jws",
          "signature_alg" => "RS256"
        },
        "issued_at" => DateTime.to_iso8601(issued_at)
      }
      |> prune_nil_values()

    Map.put(payload, "signature", signature_document(payload, provider_base_url))
  end

  def document(_, _, _), do: nil

  defp profile_document(user, domain, account_base_url) do
    %{
      "url" => account_base_url <> "/",
      "handle" => user.handle || user.username,
      "username" => user.username,
      "display_name" => blank_to_nil(user.display_name || user.handle || user.username),
      "avatar_url" => public_avatar_url(user),
      "domain_verified" => true,
      "domain_account" => account_base_url <> "/.well-known/domain-account",
      "atomine" => account_base_url <> "/.well-known/atomine",
      "webfinger" => "acct:#{ActivityPub.actor_identifier(user)}@#{domain}"
    }
  end

  defp federation_document(user, domain, account_base_url) do
    %{
      "activitypub_actor" => ActivityPub.actor_uri(user, account_base_url),
      "webfinger" => account_base_url <> "/.well-known/webfinger",
      "activitypub_webfinger" => "acct:#{ActivityPub.actor_identifier(user)}@#{domain}",
      "atproto_did" => bluesky_did_for_user(user)
    }
    |> prune_nil_values()
  end

  defp claims(user, domain, account_base_url) do
    trust_info = TrustLevel.get_level_info(user.trust_level)

    [
      %{
        "type" => "domain.verified",
        "value" => true,
        "subject" => domain,
        "evidence" => "profile_domain_discovery"
      },
      %{
        "type" => "domain_account.subject",
        "value" => DomainAccount.subject(domain)
      },
      %{
        "type" => "did.web",
        "value" => DomainAccount.did_for_domain(domain)
      },
      %{
        "type" => "profile.public_url",
        "value" => account_base_url <> "/"
      },
      %{
        "type" => "activitypub.actor",
        "value" => ActivityPub.actor_uri(user, account_base_url)
      },
      %{
        "type" => "webfinger",
        "value" => "acct:#{ActivityPub.actor_identifier(user)}@#{domain}"
      },
      %{
        "type" => "account.age",
        "days" => account_age_days(user),
        "created_at" => iso8601(user.inserted_at)
      },
      %{
        "type" => "elektrine.trust_level",
        "value" => user.trust_level,
        "label" => trust_info.name
      },
      bluesky_claim(user)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&prune_nil_values/1)
  end

  defp bluesky_claim(user) do
    case bluesky_did_for_user(user) do
      "did:" <> _ = did ->
        %{"type" => "atproto.did", "value" => did}

      _ ->
        nil
    end
  end

  defp atomine_proofs(%User{id: user_id}) do
    user_id
    |> Personhood.list_proofs()
    |> Enum.map(fn proof ->
      %{
        "id" => proof.id,
        "kind" => proof.kind,
        "claim_type" => proof.claim_type,
        "mode" => proof.proof_mode,
        "status" => proof.status,
        "verification_method" => proof.verification_method,
        "subject" => proof.subject,
        "evidence_url" => blank_to_nil(proof.evidence_url),
        "score_weight" => proof.score_weight,
        "checked_at" => iso8601(proof.checked_at),
        "verified_at" => iso8601(proof.verified_at),
        "live_status" => blank_to_nil(proof.live_status),
        "metadata" => proof.metadata || %{}
      }
      |> prune_nil_values()
    end)
  end

  defp signature_document(payload, provider_base_url) do
    jws = OIDC.sign_claims(payload, @signature_typ)
    [header, _claims, _signature] = String.split(jws, ".", parts: 3)

    %{
      "format" => "jws",
      "alg" => "RS256",
      "typ" => @signature_typ,
      "protected" => header,
      "value" => jws,
      "jwks_uri" => provider_base_url <> "/oauth/jwks"
    }
  end

  defp account_age_days(%{inserted_at: %DateTime{} = inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :day)
    |> max(0)
  end

  defp account_age_days(%{inserted_at: %NaiveDateTime{} = inserted_at}) do
    inserted_at
    |> DateTime.from_naive!("Etc/UTC")
    |> then(&DateTime.diff(DateTime.utc_now(), &1, :day))
    |> max(0)
  end

  defp account_age_days(_), do: 0

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp iso8601(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  defp iso8601(_), do: nil

  defp public_avatar_url(%{avatar: avatar}) when is_binary(avatar) and avatar != "" do
    Uploads.avatar_url(avatar)
  end

  defp public_avatar_url(_), do: nil

  defp bluesky_did_for_user(%{bluesky_did: "did:" <> _ = did}), do: String.trim(did)
  defp bluesky_did_for_user(%{bluesky_identifier: "did:" <> _ = did}), do: String.trim(did)
  defp bluesky_did_for_user(_), do: nil

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
