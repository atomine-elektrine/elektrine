defmodule Elektrine.Email.Suppression do
  @moduledoc """
  Schema for outbound recipient suppressions (bounces/complaints/manual blocks).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "email_suppressions" do
    field :email, :string
    field :reason, :string
    field :source, :string, default: "manual"
    field :note, :string
    field :metadata, :map, default: %{}
    field :last_event_at, :utc_datetime
    field :expires_at, :utc_datetime

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(suppression, attrs) do
    suppression
    |> cast(attrs, [
      :user_id,
      :email,
      :reason,
      :source,
      :note,
      :metadata,
      :last_event_at,
      :expires_at
    ])
    |> validate_required([:user_id, :email, :reason, :source, :last_event_at])
    |> normalize_email()
    |> validate_length(:email, max: 320)
    |> validate_length(:reason, max: 80)
    |> validate_length(:source, max: 80)
    |> validate_length(:note, max: 1000)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> unique_constraint([:user_id, :email])
    |> foreign_key_constraint(:user_id)
  end

  defp normalize_email(changeset) do
    case get_change(changeset, :email) do
      nil ->
        changeset

      email when is_binary(email) ->
        put_change(changeset, :email, email |> String.trim() |> String.downcase())

      _ ->
        changeset
    end
  end
end
