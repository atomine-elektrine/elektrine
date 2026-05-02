defmodule Atomine.Attestation do
  @moduledoc """
  Portable anti-bot attestation issued by Atomine.

  Attestations cover proof-of-effort receipts, passkey-bound continuity receipts,
  and anonymous effort token MVPs. Domain/web identity claims remain represented by
  `Atomine.Proof` because they are durable public discovery claims.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(pow_receipt anonymous_effort_token passkey_receipt)
  @statuses ~w(issued redeemed expired revoked)

  schema "atomine_attestations" do
    field :public_id, :string
    belongs_to :user, Elektrine.Accounts.User
    belongs_to :passkey_credential, Elektrine.Accounts.PasskeyCredential
    field :kind, :string
    field :status, :string, default: "issued"
    field :issuer, :string
    field :subject, :string
    field :subject_hash, :string
    field :artifact_hash, :string
    field :artifact, :string
    field :difficulty, :integer
    field :metadata, :map, default: %{}
    field :issued_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :redeemed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(attestation, attrs) do
    attestation
    |> cast(attrs, [
      :public_id,
      :user_id,
      :passkey_credential_id,
      :kind,
      :status,
      :issuer,
      :subject,
      :subject_hash,
      :artifact_hash,
      :artifact,
      :difficulty,
      :metadata,
      :issued_at,
      :expires_at,
      :redeemed_at
    ])
    |> validate_required([
      :public_id,
      :kind,
      :status,
      :issuer,
      :artifact_hash,
      :artifact,
      :issued_at,
      :expires_at
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:public_id, max: 120)
    |> validate_length(:issuer, max: 255)
    |> validate_length(:subject_hash, max: 128)
    |> validate_length(:artifact_hash, max: 128)
    |> validate_number(:difficulty, greater_than_or_equal_to: 0, less_than_or_equal_to: 64)
    |> unique_constraint(:public_id)
    |> unique_constraint(:artifact_hash)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:passkey_credential_id)
  end
end
