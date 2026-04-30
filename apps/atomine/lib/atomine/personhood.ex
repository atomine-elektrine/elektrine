defmodule Atomine.Personhood do
  @moduledoc """
  Proof-of-personhood and anti-bot scoring context.

  This app owns personhood proof lifecycle and scoring. Other apps can consume
  `personhood_score/1` or `sufficiently_human?/2` when deciding whether to raise
  limits, allow sensitive actions, or reduce anti-bot friction.
  """

  import Ecto.Query, warn: false

  alias Atomine.Proof
  alias Atomine.Scoring
  alias Elektrine.Accounts.User
  alias Elektrine.Repo

  @live_check_interval_days 30
  @live_stale_after_days 45

  @proof_weights %{
    "web" => 20,
    "dns" => 25,
    "social" => 15,
    "vouch" => 30,
    "payment" => 25,
    "passkey" => 20,
    "manual" => 100
  }

  @doc "Returns default score weights by proof kind."
  def proof_weights, do: @proof_weights

  @doc "Lists a user's proofs newest first."
  def list_proofs(user_id) when is_integer(user_id) do
    Proof
    |> where([p], p.user_id == ^user_id)
    |> order_by([p], desc: p.inserted_at)
    |> Repo.all()
  end

  def list_proofs(_), do: []

  @doc "Lists proofs needing human/admin review."
  def list_pending_proofs do
    Proof
    |> where([p], p.status == "pending")
    |> order_by([p], asc: p.inserted_at)
    |> Repo.all()
  end

  def get_proof!(id), do: Repo.get!(Proof, id)

  @doc "Creates a pending proof with a public challenge string."
  def create_proof(%User{} = user, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    kind = attrs |> Map.get("kind", "") |> normalize_kind()

    verification_method =
      attrs |> Map.get("verification_method", default_method_for_kind(kind)) |> normalize_method()

    proof_mode = attrs |> Map.get("proof_mode", "snapshot") |> normalize_proof_mode()
    challenge = Map.get(attrs, "challenge") || generate_challenge(user, kind)

    %Proof{}
    |> Proof.changeset(%{
      user_id: user.id,
      kind: kind,
      claim_type: "positive",
      proof_mode: proof_mode,
      live_status: initial_live_status(proof_mode),
      verification_method: verification_method,
      subject: Map.get(attrs, "subject"),
      status: "pending",
      challenge: challenge,
      evidence_url: Map.get(attrs, "evidence_url"),
      score_weight: Map.get(attrs, "score_weight") || Map.get(@proof_weights, kind, 0),
      metadata: proof_metadata(Map.get(attrs, "metadata"), verification_method, challenge)
    })
    |> Repo.insert()
  end

  @doc "Creates a hosted negative assertion, such as `I am not on Twitter`."
  def create_negative_assertion(%User{} = user, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)
    kind = attrs |> Map.get("kind", "social") |> normalize_kind()
    challenge = Map.get(attrs, "challenge") || generate_challenge(user, kind)

    %Proof{}
    |> Proof.changeset(%{
      user_id: user.id,
      kind: kind,
      claim_type: "negative",
      proof_mode: "snapshot",
      live_status: nil,
      verification_method: "none",
      subject: Map.get(attrs, "subject"),
      status: "asserted",
      challenge: challenge,
      evidence_url: Map.get(attrs, "evidence_url"),
      score_weight: 0,
      metadata: proof_metadata(Map.get(attrs, "metadata"), "none", challenge)
    })
    |> Repo.insert()
  end

  @doc "Marks a proof verified and makes its weight count toward personhood score."
  def verify_proof(%Proof{} = proof, reviewer \\ nil, notes \\ nil) do
    now = now()

    proof
    |> Proof.changeset(%{
      status: "verified",
      checked_at: now,
      last_seen_at: live_timestamp(proof, now),
      next_check_at: next_check_at(proof, now),
      stale_at: stale_at(proof, now),
      live_status: verified_live_status(proof),
      failed_check_count: 0,
      verified_at: now,
      rejected_at: nil,
      revoked_at: nil,
      reviewed_by_user_id: reviewer_id(reviewer),
      review_notes: notes
    })
    |> Repo.update()
  end

  @doc "Rejects a pending proof without contributing score."
  def reject_proof(%Proof{} = proof, reviewer \\ nil, notes \\ nil) do
    proof
    |> Proof.changeset(%{
      status: "rejected",
      checked_at: now(),
      live_status: rejected_live_status(proof),
      rejected_at: now(),
      verified_at: nil,
      revoked_at: nil,
      reviewed_by_user_id: reviewer_id(reviewer),
      review_notes: notes
    })
    |> Repo.update()
  end

  @doc "Revokes a previously accepted proof."
  def revoke_proof(%Proof{} = proof, reviewer \\ nil, notes \\ nil) do
    proof
    |> Proof.changeset(%{
      status: "revoked",
      live_status: revoked_live_status(proof),
      revoked_at: now(),
      verified_at: nil,
      rejected_at: nil,
      reviewed_by_user_id: reviewer_id(reviewer),
      review_notes: notes
    })
    |> Repo.update()
  end

  @doc "Marks a live proof stale after an overdue or failed recheck."
  def mark_live_stale(proof, notes \\ nil)

  def mark_live_stale(%Proof{proof_mode: "live"} = proof, notes) do
    proof
    |> Proof.changeset(%{
      live_status: "stale",
      failed_check_count: proof.failed_check_count + 1,
      checked_at: now(),
      review_notes: notes || proof.review_notes
    })
    |> Repo.update()
  end

  def mark_live_stale(%Proof{} = proof, _notes), do: {:ok, proof}

  @doc "Marks a live proof inactive when its snippet can no longer be found."
  def mark_live_inactive(proof, notes \\ nil)

  def mark_live_inactive(%Proof{proof_mode: "live"} = proof, notes) do
    proof
    |> Proof.changeset(%{
      live_status: "inactive",
      failed_check_count: proof.failed_check_count + 1,
      checked_at: now(),
      review_notes: notes || proof.review_notes
    })
    |> Repo.update()
  end

  def mark_live_inactive(%Proof{} = proof, _notes), do: {:ok, proof}

  @doc "Returns a detailed composite personhood score breakdown."
  def personhood_breakdown(user_or_id), do: Scoring.breakdown(user_or_id)

  @doc "Returns the capped composite personhood score for a user."
  def personhood_score(user_or_id), do: personhood_breakdown(user_or_id).score

  @doc "Returns a coarse label for UI and policy decisions."
  def personhood_level(user_or_id) do
    personhood_breakdown(user_or_id).level
  end

  @doc "Returns whether a user has enough personhood score for a policy gate."
  def sufficiently_human?(user_or_id, minimum_score \\ 40) when is_integer(minimum_score) do
    personhood_score(user_or_id) >= minimum_score
  end

  @doc "Returns the claim snippet users should publish for page-based proofs."
  def page_snippet(%Proof{} = proof), do: proof.challenge

  @doc "Returns DNS TXT record instructions for DNS-based proofs."
  def dns_txt_record(%Proof{verification_method: "dns"} = proof) do
    {"_atomine", proof.challenge}
  end

  def dns_txt_record(%Proof{}), do: nil

  defp generate_challenge(%User{} = user, kind) do
    token = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    handle = user.handle || user.username || "user-#{user.id}"

    "Atomine personhood proof for @#{handle}: #{kind}:#{token}"
  end

  defp stringify_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_kind(kind) when is_binary(kind), do: kind |> String.trim() |> String.downcase()
  defp normalize_kind(_), do: ""

  defp normalize_method(method) when is_binary(method),
    do: method |> String.trim() |> String.downcase()

  defp normalize_method(_), do: "manual"

  defp normalize_proof_mode("live"), do: "live"
  defp normalize_proof_mode(_), do: "snapshot"

  defp default_method_for_kind("dns"), do: "dns"
  defp default_method_for_kind("web"), do: "page"
  defp default_method_for_kind("social"), do: "page"
  defp default_method_for_kind(_), do: "manual"

  defp proof_metadata(metadata, verification_method, challenge) when is_map(metadata) do
    Map.merge(
      %{"verification_snippet" => challenge, "verification_method" => verification_method},
      metadata
    )
  end

  defp proof_metadata(_metadata, verification_method, challenge) do
    %{"verification_snippet" => challenge, "verification_method" => verification_method}
  end

  defp initial_live_status("live"), do: "stale"
  defp initial_live_status(_), do: nil

  defp verified_live_status(%Proof{proof_mode: "live"}), do: "active"
  defp verified_live_status(%Proof{} = proof), do: proof.live_status

  defp rejected_live_status(%Proof{proof_mode: "live"}), do: "inactive"
  defp rejected_live_status(%Proof{} = proof), do: proof.live_status

  defp revoked_live_status(%Proof{proof_mode: "live"}), do: "inactive"
  defp revoked_live_status(%Proof{} = proof), do: proof.live_status

  defp live_timestamp(%Proof{proof_mode: "live"}, now), do: now
  defp live_timestamp(%Proof{} = proof, _now), do: proof.last_seen_at

  defp next_check_at(%Proof{proof_mode: "live"}, now),
    do: DateTime.add(now, @live_check_interval_days, :day)

  defp next_check_at(%Proof{} = proof, _now), do: proof.next_check_at

  defp stale_at(%Proof{proof_mode: "live"}, now),
    do: DateTime.add(now, @live_stale_after_days, :day)

  defp stale_at(%Proof{} = proof, _now), do: proof.stale_at

  defp reviewer_id(%User{id: id}), do: id
  defp reviewer_id(id) when is_integer(id), do: id
  defp reviewer_id(_), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
