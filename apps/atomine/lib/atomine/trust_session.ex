defmodule Atomine.TrustSession do
  @moduledoc """
  A short-lived trust decision session for checkout, signup, and other external flows.

  Sessions can be attached to an Elektrine user or created for a guest/external
  subject first, then upgraded later if the customer creates an account.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @contexts ~w(checkout signup account_action api_access community_access seller_onboarding manual)
  @statuses ~w(pending step_up completed expired cancelled)
  @decisions ~w(allow step_up review block)
  @step_ups ~w(passkey email proof manual none)
  @levels ~w(unknown low medium high)

  schema "atomine_trust_sessions" do
    field :public_id, :string
    belongs_to :user, Elektrine.Accounts.User
    field :context, :string
    field :merchant_id, :string
    field :external_subject, :string
    field :status, :string, default: "pending"
    field :decision, :string, default: "review"
    field :recommended_step_up, :string
    field :score, :integer, default: 0
    field :level, :string, default: "unknown"
    field :signals, :map, default: %{}
    field :metadata, :map, default: %{}
    field :expires_at, :utc_datetime
    field :completed_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def contexts, do: @contexts
  def statuses, do: @statuses
  def decisions, do: @decisions
  def step_ups, do: @step_ups
  def levels, do: @levels

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :public_id,
      :user_id,
      :context,
      :merchant_id,
      :external_subject,
      :status,
      :decision,
      :recommended_step_up,
      :score,
      :level,
      :signals,
      :metadata,
      :expires_at,
      :completed_at
    ])
    |> normalize_string(:context)
    |> normalize_string(:status)
    |> normalize_string(:decision)
    |> normalize_string(:recommended_step_up)
    |> normalize_string(:level)
    |> normalize_optional_string(:merchant_id)
    |> normalize_optional_string(:external_subject)
    |> put_public_id()
    |> validate_required([:public_id, :context, :status, :decision, :score, :level])
    |> validate_inclusion(:context, @contexts)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:decision, @decisions)
    |> validate_inclusion(:recommended_step_up, @step_ups)
    |> validate_inclusion(:level, @levels)
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_required_subject()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:public_id)
  end

  defp validate_required_subject(changeset) do
    if get_field(changeset, :user_id) || present?(get_field(changeset, :external_subject)) do
      changeset
    else
      add_error(changeset, :external_subject, "or user is required")
    end
  end

  defp put_public_id(changeset) do
    case get_field(changeset, :public_id) do
      value when is_binary(value) and value != "" -> changeset
      _ -> put_change(changeset, :public_id, generate_public_id())
    end
  end

  defp generate_public_id do
    "ats_" <> (:crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false))
  end

  defp normalize_string(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      value -> value
    end)
  end

  defp normalize_optional_string(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> value |> String.trim() |> blank_to_nil()
      value -> value
    end)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
