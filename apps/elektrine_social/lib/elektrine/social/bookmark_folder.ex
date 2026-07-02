defmodule Elektrine.Social.BookmarkFolder do
  @moduledoc """
  User-owned folder for saved posts.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "bookmark_folders" do
    belongs_to :user, Elektrine.Accounts.User

    field :name, :string
    field :emoji, :string

    timestamps()
  end

  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [:user_id, :name, :emoji])
    |> validate_required([:user_id, :name])
    |> update_change(:name, &String.trim/1)
    |> update_change(:emoji, &trim_blank_to_nil/1)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:emoji, max: 32)
    |> unique_constraint([:user_id, :name])
    |> foreign_key_constraint(:user_id)
  end

  defp trim_blank_to_nil(nil), do: nil

  defp trim_blank_to_nil(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
