defmodule Elektrine.Notes.NoteShare do
  @moduledoc """
  Public share links for user-owned notes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Notes.Note

  schema "note_shares" do
    field :token, :string
    field :revoked_at, :utc_datetime
    field :view_count, :integer, default: 0

    belongs_to :note, Note
    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(share, attrs) do
    share
    |> cast(attrs, [:note_id, :user_id, :token, :revoked_at, :view_count])
    |> validate_required([:note_id, :user_id, :token])
    |> validate_length(:token, min: 16, max: 255)
    |> validate_number(:view_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:note_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token)
  end
end
