defmodule Elektrine.Notes.NoteShare do
  @moduledoc """
  Public share links for user-owned notes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Notes.Note

  schema "note_shares" do
    field :token, :string
    field :encrypted_payload, :map
    field :expires_at, :utc_datetime
    field :burn_after_read, :boolean, default: false
    field :revoked_at, :utc_datetime
    field :view_count, :integer, default: 0

    belongs_to :note, Note
    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(share, attrs) do
    share
    |> cast(attrs, [
      :note_id,
      :user_id,
      :token,
      :encrypted_payload,
      :expires_at,
      :burn_after_read,
      :revoked_at,
      :view_count
    ])
    |> validate_required([:note_id, :user_id, :token])
    |> validate_length(:token, min: 16, max: 255)
    |> validate_number(:view_count, greater_than_or_equal_to: 0)
    |> validate_expiry()
    |> foreign_key_constraint(:note_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token)
  end

  defp validate_expiry(changeset) do
    case get_change(changeset, :expires_at) do
      %DateTime{} = expires_at ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          changeset
        else
          add_error(changeset, :expires_at, "must be in the future")
        end

      nil ->
        changeset

      _ ->
        add_error(changeset, :expires_at, "is invalid")
    end
  end
end
