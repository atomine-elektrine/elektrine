defmodule Atomine.Scoring do
  @moduledoc """
  Composite personhood scoring.

  The score intentionally mixes proof strength, account age, security posture,
  platform trust, and penalties. A single proof can help, but mature and healthy
  accounts score better than freshly-created accounts with one weak signal.
  """

  import Ecto.Query, warn: false

  alias Atomine.Proof
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  @max_score 100
  @diversity_bonus_per_kind 5
  @max_diversity_bonus 15

  @doc "Returns a detailed personhood score breakdown for a user."
  def breakdown(%User{} = user) do
    proofs = verified_proofs(user.id)

    positive = %{
      proofs: proof_score(proofs),
      proof_diversity: proof_diversity_bonus(proofs),
      account_age: account_age_score(user),
      security: security_score(user),
      account_history: account_history_score(user),
      platform_trust: platform_trust_score(user)
    }

    penalties = %{
      account_restrictions: account_restriction_penalty(user),
      onion_registration: onion_registration_penalty(user),
      proof_rejections: proof_rejection_penalty(user.id)
    }

    raw_score = Enum.sum(Map.values(positive)) - Enum.sum(Map.values(penalties))
    score = raw_score |> max(0) |> min(@max_score)

    %{
      score: score,
      raw_score: raw_score,
      level: level(score),
      positive: positive,
      penalties: penalties,
      verified_proof_count: length(proofs),
      verified_proof_kinds: proofs |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()
    }
  end

  def breakdown(user_id) when is_integer(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user -> breakdown(user)
      nil -> empty_breakdown()
    end
  end

  def breakdown(_), do: empty_breakdown()

  def level(score) when score >= 75, do: :high
  def level(score) when score >= 40, do: :medium
  def level(score) when score >= 15, do: :low
  def level(_), do: :unknown

  defp verified_proofs(user_id) do
    Proof
    |> where([p], p.user_id == ^user_id and p.claim_type == "positive" and p.status == "verified")
    |> Repo.all()
  end

  defp proof_score(proofs) do
    if Enum.any?(proofs, &(&1.kind == "manual" and &1.score_weight >= 100)) do
      100
    else
      proofs
      |> Enum.reduce(0, fn proof, total -> total + weighted_proof_score(proof) end)
      |> min(65)
    end
  end

  defp weighted_proof_score(%Proof{proof_mode: "live", live_status: "active"} = proof),
    do: proof.score_weight + 5

  defp weighted_proof_score(%Proof{proof_mode: "live", live_status: "stale"} = proof),
    do: div(proof.score_weight, 2)

  defp weighted_proof_score(%Proof{proof_mode: "live", live_status: "inactive"}), do: 0

  defp weighted_proof_score(%Proof{} = proof), do: proof.score_weight

  defp proof_diversity_bonus(proofs) do
    proofs
    |> Enum.map(& &1.kind)
    |> Enum.uniq()
    |> length()
    |> Kernel.-(1)
    |> max(0)
    |> Kernel.*(@diversity_bonus_per_kind)
    |> min(@max_diversity_bonus)
  end

  defp account_age_score(%User{inserted_at: inserted_at}) do
    days = account_age_days(inserted_at)

    cond do
      days >= 365 -> 20
      days >= 180 -> 16
      days >= 90 -> 12
      days >= 30 -> 8
      days >= 7 -> 4
      true -> 0
    end
  end

  defp security_score(user) do
    recovery_email_score = if user.recovery_email_verified, do: 5, else: 0
    two_factor_score = if user.two_factor_enabled, do: 10, else: 0
    passkey_score = if has_verified_kind?(user.id, "passkey"), do: 5, else: 0

    recovery_email_score + two_factor_score + passkey_score
  end

  defp account_history_score(user) do
    login_score =
      cond do
        user.login_count >= 50 -> 10
        user.login_count >= 10 -> 6
        user.login_count >= 3 -> 3
        true -> 0
      end

    seen_score = if user.last_seen_at || user.last_login_at, do: 5, else: 0
    login_score + seen_score
  end

  defp platform_trust_score(user) do
    cond do
      user.is_admin -> 15
      user.verified -> 10
      user.trust_level >= 3 -> 12
      user.trust_level >= 2 -> 8
      user.trust_level >= 1 -> 4
      true -> 0
    end
  end

  defp account_restriction_penalty(user) do
    banned = if user.banned, do: 100, else: 0
    suspended = if user.suspended, do: 50, else: 0
    email_restricted = if user.email_sending_restricted, do: 15, else: 0
    banned + suspended + email_restricted
  end

  defp onion_registration_penalty(%User{registered_via_onion: true}), do: 5
  defp onion_registration_penalty(_), do: 0

  defp proof_rejection_penalty(user_id) do
    rejected_count =
      Proof
      |> where([p], p.user_id == ^user_id and p.status in ["rejected", "revoked"])
      |> Repo.aggregate(:count)

    min(rejected_count * 10, 30)
  end

  defp has_verified_kind?(user_id, kind) do
    Repo.exists?(
      from p in Proof,
        where:
          p.user_id == ^user_id and p.kind == ^kind and p.claim_type == "positive" and
            p.status == "verified"
    )
  end

  defp account_age_days(%DateTime{} = inserted_at) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :day)
  end

  defp account_age_days(%NaiveDateTime{} = inserted_at) do
    inserted_at
    |> DateTime.from_naive!("Etc/UTC")
    |> account_age_days()
  end

  defp account_age_days(_), do: 0

  defp empty_breakdown do
    %{
      score: 0,
      raw_score: 0,
      level: :unknown,
      positive: %{},
      penalties: %{},
      verified_proof_count: 0,
      verified_proof_kinds: []
    }
  end
end
