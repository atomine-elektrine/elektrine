defmodule Elektrine.Files.StoredFolder do
  @moduledoc """
  Explicit folder records for the personal file library.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "stored_folders" do
    field :path, :string

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(folder, attrs) do
    folder
    |> cast(attrs, [:user_id, :path])
    |> validate_required([:user_id, :path])
    |> validate_length(:path, max: 500)
    |> validate_path()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :path])
  end

  defp validate_path(changeset) do
    case get_change(changeset, :path) do
      nil ->
        changeset

      path ->
        cond do
          String.trim(path) == "" ->
            add_error(changeset, :path, "cannot be blank")

          String.starts_with?(path, "/") ->
            add_error(changeset, :path, "cannot start with '/'")

          String.contains?(path, "..") ->
            add_error(changeset, :path, "cannot contain '..'")

          String.contains?(path, ["//", "\\", <<0>>]) ->
            add_error(changeset, :path, "contains invalid path segments")

          true ->
            changeset
        end
    end
  end
end
