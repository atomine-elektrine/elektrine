defmodule Elektrine.Files.StoredFile do
  @moduledoc """
  Metadata for a user-owned file stored in local or R2-backed object storage.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Files.FileShare

  schema "stored_files" do
    field :path, :string
    field :storage_key, :string
    field :original_filename, :string
    field :content_type, :string
    field :size, :integer

    belongs_to :user, Elektrine.Accounts.User
    has_many :shares, FileShare

    timestamps(type: :utc_datetime)
  end

  def changeset(file, attrs) do
    file
    |> cast(attrs, [:user_id, :path, :storage_key, :original_filename, :content_type, :size])
    |> validate_required([
      :user_id,
      :path,
      :storage_key,
      :original_filename,
      :content_type,
      :size
    ])
    |> validate_length(:path, max: 500)
    |> validate_length(:storage_key, max: 500)
    |> validate_length(:original_filename, max: 255)
    |> validate_length(:content_type, max: 255)
    |> validate_number(:size, greater_than: 0)
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

          Enum.any?(String.split(path, "/", trim: true), &(String.trim(&1) == "")) ->
            add_error(changeset, :path, "contains empty path segments")

          true ->
            changeset
        end
    end
  end
end
