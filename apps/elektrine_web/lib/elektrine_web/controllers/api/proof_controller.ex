defmodule ElektrineWeb.API.ProofController do
  @moduledoc """
  External API controller for Atomine identity proofs.
  """

  use ElektrineWeb, :controller

  alias Atomine.Personhood
  alias Atomine.Proof
  alias Elektrine.Repo
  alias ElektrineWeb.API.Response

  action_fallback ElektrineWeb.FallbackController

  @default_limit 50
  @max_limit 100

  @doc """
  GET /api/ext/v1/proofs
  """
  def index(conn, params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], @default_limit) |> min(@max_limit)

    all_proofs = Personhood.list_proofs(user.id)
    proofs = Enum.take(all_proofs, limit)

    Response.ok(
      conn,
      %{
        proofs: Enum.map(proofs, &format_proof/1),
        score: format_breakdown(Personhood.personhood_breakdown(user.id))
      },
      %{pagination: %{limit: limit, total_count: length(all_proofs)}}
    )
  end

  @doc """
  GET /api/ext/v1/proofs/score
  """
  def score(conn, _params) do
    user = conn.assigns.current_user

    Response.ok(conn, %{score: format_breakdown(Personhood.personhood_breakdown(user.id))})
  end

  @doc """
  GET /api/ext/v1/proofs/:id
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, proof_id} <- parse_id(id),
         {:ok, proof} <- get_owned_proof(user.id, proof_id) do
      Response.ok(conn, %{proof: format_proof(proof)})
    else
      :error -> Response.error(conn, :bad_request, "invalid_id", "Invalid proof id")
      {:error, :not_found} -> Response.error(conn, :not_found, "not_found", "Proof not found")
    end
  end

  @doc """
  POST /api/ext/v1/proofs
  """
  def create(conn, params) do
    user = conn.assigns.current_user
    attrs = proof_payload(params)

    result =
      if attrs.claim_type == "negative" do
        Personhood.create_negative_assertion(user, attrs)
      else
        Personhood.create_proof(user, attrs)
      end

    case result do
      {:ok, proof} ->
        Response.created(conn, %{
          proof: format_proof(proof),
          instructions: verification_instructions(proof)
        })

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  POST /api/ext/v1/proofs/:id/check
  """
  def check(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, proof_id} <- parse_id(id),
         {:ok, proof} <- get_owned_proof(user.id, proof_id) do
      case Personhood.check_proof(proof) do
        {:ok, checked_proof} ->
          Response.ok(conn, %{
            message: check_message(checked_proof),
            proof: format_proof(checked_proof)
          })

        {:error, {:not_found, checked_proof}} ->
          Response.error(
            conn,
            :unprocessable_entity,
            "challenge_not_found",
            "Proof challenge was not found",
            %{proof: format_proof(checked_proof)}
          )

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}

        {:error, reason} ->
          proof_check_error(conn, reason)
      end
    else
      :error -> Response.error(conn, :bad_request, "invalid_id", "Invalid proof id")
      {:error, :not_found} -> Response.error(conn, :not_found, "not_found", "Proof not found")
    end
  end

  @doc """
  DELETE /api/ext/v1/proofs/:id
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, proof_id} <- parse_id(id),
         {:ok, proof} <- get_owned_proof(user.id, proof_id),
         {:ok, _deleted} <- Personhood.delete_proof(proof) do
      Response.ok(conn, %{message: "Proof deleted"})
    else
      :error ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid proof id")

      {:error, :not_found} ->
        Response.error(conn, :not_found, "not_found", "Proof not found")

      {:error, _reason} ->
        Response.error(conn, :unprocessable_entity, "delete_failed", "Failed to delete proof")
    end
  end

  defp get_owned_proof(user_id, proof_id) do
    case Repo.get(Proof, proof_id) do
      %Proof{user_id: ^user_id} = proof -> {:ok, proof}
      _ -> {:error, :not_found}
    end
  end

  defp proof_payload(params) do
    source = Map.get(params, "proof", params)
    claim_type = source |> Map.get("claim_type", "positive") |> normalize_claim_type()
    default_kind = if claim_type == "negative", do: "social", else: "dns"
    kind = source |> Map.get("kind", default_kind) |> normalize_proof_kind()
    subject = Map.get(source, "subject") || Map.get(source, "target")

    %{
      kind: kind,
      claim_type: claim_type,
      subject: subject,
      evidence_url:
        normalized_evidence_url(claim_type, kind, subject, Map.get(source, "evidence_url")),
      proof_mode: Map.get(source, "proof_mode", default_mode(kind))
    }
  end

  defp normalize_proof_kind(kind) when is_binary(kind) do
    kind = kind |> String.trim() |> String.downcase()
    if kind in ["dns", "web", "social"], do: kind, else: "dns"
  end

  defp normalize_proof_kind(_), do: "dns"

  defp normalize_claim_type(claim_type) when is_binary(claim_type) do
    if String.downcase(String.trim(claim_type)) == "negative", do: "negative", else: "positive"
  end

  defp normalize_claim_type(_), do: "positive"

  defp default_mode(kind) when kind in ["dns", "web", "social"], do: "live"
  defp default_mode(_), do: "snapshot"

  defp normalized_evidence_url("negative", _kind, _subject, ""), do: nil
  defp normalized_evidence_url("negative", _kind, _subject, nil), do: nil
  defp normalized_evidence_url("negative", _kind, _subject, evidence_url), do: evidence_url

  defp normalized_evidence_url(_claim_type, kind, subject, _evidence_url)
       when kind in ["web", "social"],
       do: subject

  defp normalized_evidence_url(_claim_type, "dns", _subject, _evidence_url), do: nil
  defp normalized_evidence_url(_claim_type, _kind, _subject, ""), do: nil
  defp normalized_evidence_url(_claim_type, _kind, _subject, evidence_url), do: evidence_url

  defp format_proof(%Proof{} = proof) do
    %{
      id: proof.id,
      kind: proof.kind,
      claim_type: proof.claim_type,
      proof_mode: proof.proof_mode,
      live_status: proof.live_status,
      verification_method: proof.verification_method,
      subject: proof.subject,
      status: proof.status,
      challenge: proof.challenge,
      evidence_url: proof.evidence_url,
      score_weight: proof.score_weight,
      checked_at: proof.checked_at,
      last_seen_at: proof.last_seen_at,
      next_check_at: proof.next_check_at,
      stale_at: proof.stale_at,
      failed_check_count: proof.failed_check_count,
      verified_at: proof.verified_at,
      rejected_at: proof.rejected_at,
      revoked_at: proof.revoked_at,
      review_notes: proof.review_notes,
      created_at: proof.inserted_at,
      updated_at: proof.updated_at,
      verification: verification_instructions(proof)
    }
  end

  defp verification_instructions(%Proof{} = proof) do
    base = %{
      method: proof.verification_method,
      challenge: proof.challenge
    }

    case proof.verification_method do
      "dns" ->
        {txt_name, txt_value} = Personhood.dns_txt_record(proof)

        Map.merge(base, %{
          dns_txt_name: txt_name,
          dns_txt_host: Personhood.dns_txt_host(proof),
          dns_txt_value: txt_value
        })

      method when method in ["page", "github_gist"] ->
        Map.merge(base, %{
          page_snippet: Personhood.page_snippet(proof),
          evidence_url: proof.evidence_url
        })

      _ ->
        base
    end
  end

  defp format_breakdown(breakdown) when is_map(breakdown) do
    breakdown
    |> Map.update(:level, "unknown", &to_string/1)
  end

  defp check_message(%Proof{status: "verified"}), do: "Proof verified"
  defp check_message(%Proof{}), do: "Proof checked"

  defp proof_check_error(conn, :manual_review_required) do
    Response.error(
      conn,
      :unprocessable_entity,
      "manual_review_required",
      "This proof requires manual review"
    )
  end

  defp proof_check_error(conn, :not_checkable) do
    Response.error(conn, :unprocessable_entity, "not_checkable", "This proof cannot be checked")
  end

  defp proof_check_error(conn, :closed) do
    Response.error(conn, :unprocessable_entity, "closed", "This proof is closed")
  end

  defp proof_check_error(conn, reason) do
    Response.error(
      conn,
      :unprocessable_entity,
      "check_failed",
      "Proof check failed",
      inspect(reason)
    )
  end

  defp parse_id(value) when is_integer(value), do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value
  defp parse_positive_int(value, default) when is_integer(value), do: default

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_value, default), do: default
end
