defmodule Elektrine.OIDC do
  @moduledoc """
  OpenID Connect helpers built on top of the existing OAuth tables.
  """

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.SigningKey, as: ActivityPubSigningKey
  alias Elektrine.Domains
  alias Elektrine.EmailAddresses
  alias Elektrine.OAuth.Scopes
  alias Elektrine.OAuth.Token
  alias Elektrine.OIDC.SigningKey
  alias Elektrine.Uploads

  @openid_scopes ["openid", "profile", "email"]

  @spec openid_scopes() :: [String.t()]
  def openid_scopes, do: @openid_scopes

  @spec openid_request?([String.t()]) :: boolean()
  def openid_request?(scopes) when is_list(scopes), do: "openid" in scopes

  @spec issue_id_token(
          Token.t(),
          User.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          DateTime.t() | nil
        ) :: String.t()
  def issue_id_token(
        %Token{} = token,
        %User{} = user,
        issuer,
        client_id,
        nonce \\ nil,
        auth_time \\ nil
      ) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    claims = %{
      "iss" => issuer,
      "sub" => subject_for_user(user),
      "aud" => client_id,
      "exp" => DateTime.to_unix(token.valid_until),
      "iat" => DateTime.to_unix(now),
      "auth_time" => DateTime.to_unix(auth_time || token.oidc_auth_time || now)
    }

    claims =
      if is_binary(nonce) and nonce != "" do
        Map.put(claims, "nonce", nonce)
      else
        claims
      end

    jwt_rs256(claims)
  end

  @spec userinfo_claims(User.t(), [String.t()], String.t()) :: map()
  def userinfo_claims(%User{} = user, scopes, issuer) do
    %{"sub" => subject_for_user(user)}
    |> maybe_add_profile_claims(user, scopes, issuer)
    |> maybe_add_email_claims(user, scopes)
  end

  @spec discovery_document(String.t()) :: map()
  def discovery_document(issuer) do
    %{
      issuer: issuer,
      authorization_endpoint: issuer <> "/oauth/authorize",
      token_endpoint: issuer <> "/oauth/token",
      userinfo_endpoint: issuer <> "/oauth/userinfo",
      jwks_uri: issuer <> "/oauth/jwks",
      response_types_supported: ["code"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"],
      scopes_supported: Enum.uniq(openid_scopes() ++ Scopes.valid_scopes()),
      claims_supported: [
        "sub",
        "preferred_username",
        "nickname",
        "name",
        "profile",
        "picture",
        "updated_at",
        "zoneinfo",
        "locale",
        "email",
        "email_verified"
      ],
      token_endpoint_auth_methods_supported: ["client_secret_post", "client_secret_basic"],
      grant_types_supported: ["authorization_code", "refresh_token"]
    }
  end

  @spec jwks() :: map()
  def jwks do
    %{
      keys: [jwk_for_signing_key(current_signing_key())]
    }
  end

  defp maybe_add_profile_claims(claims, user, scopes, issuer) do
    if "profile" in scopes do
      profile_claims = %{
        "preferred_username" => user.handle || user.username,
        "nickname" => user.username,
        "name" => user.display_name || user.username,
        "profile" => profile_url(user, issuer),
        "picture" => user.avatar |> Uploads.avatar_url() |> absolutize_url(),
        "updated_at" => DateTime.to_unix(user.updated_at),
        "zoneinfo" => user.timezone,
        "locale" => user.locale
      }

      Map.merge(claims, compact_map(profile_claims))
    else
      claims
    end
  end

  defp maybe_add_email_claims(claims, user, scopes) do
    if "email" in scopes do
      Map.merge(claims, %{
        "email" => EmailAddresses.primary_for_user(user),
        "email_verified" => user.verified == true
      })
    else
      claims
    end
  end

  defp current_signing_key do
    SigningKey.current() || generate_signing_key()
  end

  defp generate_signing_key do
    {public_key_pem, private_key_pem} = ActivityPubSigningKey.generate_key_pair()

    SigningKey.create!(%{
      kid: "oidc-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      alg: "RS256",
      public_key_pem: public_key_pem,
      private_key_pem: private_key_pem,
      active: true
    })
  end

  defp jwk_for_signing_key(signing_key) do
    {:RSAPublicKey, modulus, exponent} = decode_public_key!(signing_key.public_key_pem)

    %{
      kty: "RSA",
      use: "sig",
      alg: signing_key.alg,
      kid: signing_key.kid,
      n: encode_integer_component(modulus),
      e: encode_integer_component(exponent)
    }
  end

  defp subject_for_user(%User{unique_id: unique_id})
       when is_binary(unique_id) and unique_id != "" do
    unique_id
  end

  defp subject_for_user(%User{id: id}), do: to_string(id)

  defp jwt_rs256(claims) do
    signing_key = current_signing_key()
    header = %{"alg" => signing_key.alg, "typ" => "JWT", "kid" => signing_key.kid}
    encoded_header = base64url_json(header)
    encoded_claims = base64url_json(claims)
    signing_input = encoded_header <> "." <> encoded_claims

    signature =
      signing_key.private_key_pem
      |> decode_private_key!()
      |> then(&:public_key.sign(signing_input, :sha256, &1))
      |> Base.url_encode64(padding: false)

    signing_input <> "." <> signature
  end

  defp decode_public_key!(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  defp decode_private_key!(pem) do
    [entry] = :public_key.pem_decode(pem)
    :public_key.pem_entry_decode(entry)
  end

  defp encode_integer_component(integer) when is_integer(integer) do
    integer
    |> :binary.encode_unsigned()
    |> Base.url_encode64(padding: false)
  end

  defp base64url_json(data) do
    data
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
  end

  defp absolutize_url(nil), do: nil
  defp absolutize_url(""), do: nil
  defp absolutize_url("http://" <> _ = url), do: url
  defp absolutize_url("https://" <> _ = url), do: url

  defp absolutize_url("/" <> path),
    do: Domains.public_base_url() <> "/" <> String.trim_leading(path, "/")

  defp absolutize_url(path),
    do: Domains.public_base_url() <> "/" <> String.trim_leading(path, "/")

  defp profile_url(user, issuer) do
    case Domains.profile_url_for_handle(user.handle || user.username) do
      nil -> issuer <> "/" <> (user.handle || user.username)
      url -> url
    end
  end
end
