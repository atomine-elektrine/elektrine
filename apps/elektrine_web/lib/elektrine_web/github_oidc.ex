defmodule ElektrineWeb.GitHubOIDC do
  @moduledoc false

  @issuer "https://token.actions.githubusercontent.com"
  @jwks_url "https://token.actions.githubusercontent.com/.well-known/jwks"

  def verify(token, audience) when is_binary(token) and is_binary(audience) do
    with [header64, payload64, sig64] <- String.split(token, "."),
         {:ok, header} <- decode_json_part(header64),
         {:ok, claims} <- decode_json_part(payload64),
         {:ok, signature} <- base64url_decode(sig64),
         :ok <- validate_claims(claims, audience),
         {:ok, jwk} <- fetch_jwk(header["kid"]),
         :ok <- verify_signature(jwk, header64 <> "." <> payload64, signature) do
      {:ok, claims}
    else
      _ -> {:error, :invalid_github_oidc_token}
    end
  end

  def verify(_token, _audience), do: {:error, :invalid_github_oidc_token}

  defp decode_json_part(part) do
    with {:ok, json} <- base64url_decode(part), do: Jason.decode(json)
  end

  defp validate_claims(%{"iss" => @issuer, "aud" => audience, "exp" => exp} = claims, audience) do
    now = System.system_time(:second)
    nbf = Map.get(claims, "nbf", now - 1)

    if exp > now and nbf <= now and is_binary(claims["repository"]) do
      :ok
    else
      {:error, :invalid_claims}
    end
  end

  defp validate_claims(_claims, _audience), do: {:error, :invalid_claims}

  defp fetch_jwk(kid) when is_binary(kid) do
    with {:ok, %{status: status, body: body}} when status in 200..299 <- Req.get(@jwks_url),
         %{"keys" => keys} <- body,
         %{} = jwk <- Enum.find(keys, &(&1["kid"] == kid)) do
      {:ok, jwk}
    else
      _ -> {:error, :jwk_not_found}
    end
  end

  defp verify_signature(%{"kty" => "RSA", "n" => n64, "e" => e64}, signing_input, signature) do
    with {:ok, n_bin} <- base64url_decode(n64),
         {:ok, e_bin} <- base64url_decode(e64) do
      key = {:RSAPublicKey, :binary.decode_unsigned(n_bin), :binary.decode_unsigned(e_bin)}

      if :public_key.verify(signing_input, :sha256, signature, key) do
        :ok
      else
        {:error, :bad_signature}
      end
    end
  end

  defp verify_signature(_jwk, _signing_input, _signature), do: {:error, :unsupported_key}

  defp base64url_decode(value) do
    value
    |> String.replace("-", "+")
    |> String.replace("_", "/")
    |> pad64()
    |> Base.decode64()
  end

  defp pad64(value) do
    value <> String.duplicate("=", rem(4 - rem(byte_size(value), 4), 4))
  end
end
