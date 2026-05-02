defmodule Atomine.Proof do
  @moduledoc """
  A proof signal used to establish that an account belongs to a real person.

  Proofs are intentionally separate from `Accounts.User.verified`; they are
  anti-bot/personhood signals that can be combined into a score.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(web dns social vouch payment passkey manual)
  @claim_types ~w(positive negative)
  @proof_modes ~w(snapshot live)
  @live_statuses ~w(active stale inactive)
  @verification_methods ~w(page dns github_gist email oauth manual none)
  @statuses ~w(pending asserted verified rejected revoked)

  schema "atomine_proofs" do
    belongs_to :user, Elektrine.Accounts.User
    field :kind, :string
    field :claim_type, :string, default: "positive"
    field :proof_mode, :string, default: "snapshot"
    field :live_status, :string
    field :verification_method, :string, default: "manual"
    field :subject, :string
    field :status, :string, default: "pending"
    field :challenge, :string
    field :evidence_url, :string
    field :score_weight, :integer, default: 0
    field :metadata, :map, default: %{}
    field :checked_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    field :next_check_at, :utc_datetime
    field :stale_at, :utc_datetime
    field :failed_check_count, :integer, default: 0
    field :verified_at, :utc_datetime
    field :rejected_at, :utc_datetime
    field :revoked_at, :utc_datetime
    belongs_to :reviewed_by_user, Elektrine.Accounts.User
    field :review_notes, :string

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def claim_types, do: @claim_types
  def proof_modes, do: @proof_modes
  def live_statuses, do: @live_statuses
  def verification_methods, do: @verification_methods
  def statuses, do: @statuses

  def changeset(proof, attrs) do
    proof
    |> cast(attrs, [
      :user_id,
      :kind,
      :claim_type,
      :proof_mode,
      :live_status,
      :verification_method,
      :subject,
      :status,
      :challenge,
      :evidence_url,
      :score_weight,
      :metadata,
      :checked_at,
      :last_seen_at,
      :next_check_at,
      :stale_at,
      :failed_check_count,
      :verified_at,
      :rejected_at,
      :revoked_at,
      :reviewed_by_user_id,
      :review_notes
    ])
    |> normalize_string(:kind)
    |> normalize_string(:claim_type)
    |> normalize_string(:proof_mode)
    |> normalize_string(:live_status)
    |> normalize_string(:verification_method)
    |> normalize_string(:status)
    |> normalize_subject()
    |> validate_required([
      :user_id,
      :kind,
      :claim_type,
      :proof_mode,
      :verification_method,
      :subject,
      :status,
      :challenge,
      :score_weight
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:claim_type, @claim_types)
    |> validate_inclusion(:proof_mode, @proof_modes)
    |> validate_inclusion(:live_status, @live_statuses)
    |> validate_inclusion(:verification_method, @verification_methods)
    |> validate_inclusion(:status, @statuses)
    |> validate_status_matches_claim_type()
    |> validate_live_status_matches_mode()
    |> validate_length(:subject, min: 1, max: 500)
    |> validate_length(:challenge, min: 16, max: 2_000)
    |> validate_length(:evidence_url, max: 2_000)
    |> validate_length(:review_notes, max: 5_000)
    |> validate_number(:score_weight, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:failed_check_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:reviewed_by_user_id)
    |> unique_constraint(:subject,
      name: :atomine_proofs_active_dns_subject_unique,
      message: "domain already has an active DNS proof"
    )
    |> unique_constraint(:subject,
      name: :atomine_proofs_active_subject_unique,
      message: "already has an active proof for this subject"
    )
  end

  defp validate_live_status_matches_mode(changeset) do
    proof_mode = get_field(changeset, :proof_mode)
    live_status = get_field(changeset, :live_status)

    cond do
      proof_mode == "live" and is_nil(live_status) ->
        add_error(changeset, :live_status, "is required for live proofs")

      proof_mode == "snapshot" and not is_nil(live_status) ->
        add_error(changeset, :live_status, "must be empty for snapshot proofs")

      true ->
        changeset
    end
  end

  defp validate_status_matches_claim_type(changeset) do
    claim_type = get_field(changeset, :claim_type)
    status = get_field(changeset, :status)

    cond do
      claim_type == "negative" and status == "verified" ->
        add_error(changeset, :status, "negative assertions cannot be verified")

      claim_type == "negative" and get_field(changeset, :score_weight) != 0 ->
        add_error(changeset, :score_weight, "negative assertions cannot affect score")

      true ->
        changeset
    end
  end

  defp normalize_string(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      value -> value
    end)
  end

  defp normalize_subject(changeset) do
    kind = get_field(changeset, :kind)

    update_change(changeset, :subject, fn
      value when is_binary(value) and kind == "dns" ->
        value |> String.trim() |> String.trim_trailing(".") |> String.downcase()

      value when is_binary(value) ->
        String.trim(value)

      value ->
        value
    end)
  end
end
