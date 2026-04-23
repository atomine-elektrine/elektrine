defmodule Elektrine.Drive.FileShare do
  @moduledoc """
  Public share links for user-owned files.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Drive.StoredFile

  schema "drive_shares" do
    field :token, :string
    field :revoked_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :access_level, :string, default: "download"
    field :password_hash, :string
    field :download_count, :integer, default: 0

    belongs_to :stored_file, StoredFile, foreign_key: :drive_file_id
    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(share, attrs) do
    share
    |> cast(attrs, [
      :drive_file_id,
      :user_id,
      :token,
      :revoked_at,
      :expires_at,
      :access_level,
      :password_hash,
      :download_count
    ])
    |> validate_required([:drive_file_id, :user_id, :token])
    |> validate_length(:token, min: 16, max: 255)
    |> validate_number(:download_count, greater_than_or_equal_to: 0)
    |> validate_inclusion(:access_level, ["download", "view"])
    |> validate_expiry()
    |> foreign_key_constraint(:drive_file_id)
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
