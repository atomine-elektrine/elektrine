defmodule Elektrine.Notes.Note do
  @moduledoc """
  Schema for a user's private notes.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "notes" do
    field :title, :string
    field :body, :string, default: ""
    field :pinned, :boolean, default: false

    belongs_to :user, Elektrine.Accounts.User
    has_many :shares, Elektrine.Notes.NoteShare

    timestamps(type: :utc_datetime)
  end

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:title, :body, :pinned, :user_id])
    |> update_change(:title, &normalize_optional_string/1)
    |> update_change(:body, &normalize_body/1)
    |> validate_required([:user_id])
    |> validate_length(:title, max: 255)
    |> validate_note_present()
  end

  defp validate_note_present(changeset) do
    title = get_field(changeset, :title)
    body = get_field(changeset, :body)

    if blank?(title) and blank?(body) do
      add_error(changeset, :body, "can't be blank")
    else
      changeset
    end
  end

  defp normalize_optional_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value), do: value

  defp normalize_body(value) when is_binary(value), do: String.trim(value)
  defp normalize_body(value), do: value

  defp blank?(value), do: value in [nil, ""]
end
