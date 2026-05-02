defmodule ElektrineWeb.API.AtomineAttestationController do
  use ElektrineWeb, :controller

  alias Atomine.Attestations

  def pow_challenge(conn, params) do
    difficulty = Map.get(params, "difficulty")
    {:ok, challenge} = Attestations.issue_pow_challenge(difficulty: difficulty)

    json(conn, challenge)
  end

  def pow_receipt(conn, params) do
    case Attestations.issue_pow_receipt(with_current_user(params, conn)) do
      {:ok, attestation} -> json(conn, attestation_response(attestation))
      {:error, reason} -> error(conn, reason)
    end
  end

  def anonymous_token(conn, params) do
    case Attestations.issue_anonymous_effort_token(params) do
      {:ok, attestation} -> json(conn, anonymous_token_response(attestation))
      {:error, reason} -> error(conn, reason)
    end
  end

  def redeem_anonymous_token(conn, %{"token" => token}) do
    case Attestations.redeem_anonymous_effort_token(token) do
      {:ok, attestation} ->
        json(conn, %{status: attestation.status, redeemed_at: attestation.redeemed_at})

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def redeem_anonymous_token(conn, _params), do: error(conn, :missing_token)

  def verify(conn, %{"artifact" => artifact}) do
    case Attestations.verify_artifact(artifact) do
      {:ok, result} ->
        json(conn, Map.put(result, :valid, true))

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{valid: false, error: format_reason(reason)})
    end
  end

  def verify(conn, _params), do: error(conn, :missing_artifact)

  def passkey_receipt(conn, %{"passkey_credential_id" => passkey_credential_id}) do
    case Attestations.issue_passkey_receipt(conn.assigns.current_user, passkey_credential_id) do
      {:ok, attestation} -> json(conn, attestation_response(attestation))
      {:error, reason} -> error(conn, reason)
    end
  end

  def passkey_receipt(conn, _params), do: error(conn, :missing_passkey_credential_id)

  defp attestation_response(attestation) do
    %{
      id: attestation.public_id,
      kind: attestation.kind,
      status: attestation.status,
      issuer: attestation.issuer,
      subject_hash: attestation.subject_hash,
      receipt: attestation.artifact,
      difficulty: attestation.difficulty,
      issued_at: attestation.issued_at,
      expires_at: attestation.expires_at,
      metadata: attestation.metadata
    }
  end

  defp anonymous_token_response(attestation) do
    %{
      id: attestation.public_id,
      kind: attestation.kind,
      status: attestation.status,
      issuer: attestation.issuer,
      token: attestation.artifact,
      difficulty: attestation.difficulty,
      issued_at: attestation.issued_at,
      expires_at: attestation.expires_at
    }
  end

  defp error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: format_reason(reason)})
  end

  defp with_current_user(params, conn) do
    case conn.assigns[:current_user] do
      %{id: user_id} -> Map.put(params, :user_id, user_id)
      _ -> params
    end
  end

  defp format_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp format_reason(reason), do: inspect(reason)
end
