defmodule Atomine.CreditEarningPolicy do
  @moduledoc "Policy for converting anti-abuse proof systems into Atomine Credit grants."

  alias Atomine.{Credits, Proof}

  @proof_grants %{
    "dns" => 10,
    "web" => 8,
    "social" => 5,
    "passkey" => 5,
    "payment" => 15,
    "vouch" => 10,
    "manual" => 10
  }

  @doc "Returns the proof-of-X earning systems for product/UI discovery."
  def earning_paths do
    [
      %{
        key: "proof_of_personhood",
        label: "Proof of personhood/control",
        status: :active,
        summary: "Verify DNS, web, social, GitHub, passkey, payment, or reviewed proof signals.",
        reward: "5-15 Atomine Credits per verified proof, once per proof."
      },
      %{
        key: "proof_of_stake",
        label: "Proof of stake",
        status: :planned,
        summary: "Lock stake for higher action capacity; abusive use can be slashed.",
        reward: "Planned."
      },
      %{
        key: "proof_of_work",
        label: "Proof of work",
        status: :planned,
        summary: "Spend computational or delivery-cost work to earn small temporary capacity.",
        reward: "Planned."
      },
      %{
        key: "proof_of_reputation",
        label: "Proof of reputation",
        status: :planned,
        summary: "Clean account age, low reports, accepted messages, and good delivery history.",
        reward: "Planned."
      },
      %{
        key: "proof_of_service",
        label: "Proof of service",
        status: :planned,
        summary: "Contribute useful network, moderation, or support work.",
        reward: "Planned."
      }
    ]
  end

  @doc "Returns the one-time Atomine Credit grant for a verified proof kind."
  def verified_proof_grant_amount(kind), do: Map.get(@proof_grants, to_string(kind), 0)

  @doc "Grants Atomine Credits once when an eligible proof is verified."
  def grant_for_verified_proof(%Proof{} = proof) do
    amount = verified_proof_grant_amount(proof.kind)

    cond do
      proof.claim_type != "positive" ->
        {:ok, :not_eligible}

      proof.status != "verified" ->
        {:ok, :not_verified}

      amount <= 0 ->
        {:ok, :not_eligible}

      true ->
        Credits.grant_once(
          proof.user_id,
          :atomine_credit,
          amount,
          "verified_proof:#{proof.kind}",
          action: "verified_proof",
          reference_type: "atomine_proof",
          reference_id: proof.id,
          metadata: %{
            "proof_kind" => proof.kind,
            "proof_subject" => proof.subject,
            "proof_method" => proof.verification_method
          }
        )
    end
  end
end
