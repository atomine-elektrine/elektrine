defmodule Elektrine.Profiles.StaticSiteFile do
  @moduledoc """
  Schema for static site files uploaded by users.
  Stores metadata about uploaded HTML, CSS, JS, and asset files.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "static_site_files" do
    field :path, :string
    field :storage_key, :string
    field :content_type, :string
    field :size, :integer

    belongs_to :user, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(file, attrs) do
    file
    |> cast(attrs, [:user_id, :path, :storage_key, :content_type, :size])
    |> validate_required([:user_id, :path, :storage_key, :content_type, :size])
    |> validate_length(:path, max: 500)
    |> validate_path()
    |> validate_content_type()
    |> validate_number(:size, greater_than: 0, less_than_or_equal_to: 10_000_000)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :path])
  end

  # Validate path is safe and doesn't allow directory traversal
  defp validate_path(changeset) do
    case get_change(changeset, :path) do
      nil ->
        changeset

      path ->
        cond do
          String.contains?(path, "..") ->
            add_error(changeset, :path, "cannot contain '..'")

          String.starts_with?(path, "/") ->
            add_error(changeset, :path, "cannot start with '/'")

          String.contains?(path, "//") ->
            add_error(changeset, :path, "cannot contain '//'")

          !Regex.match?(~r/^[a-zA-Z0-9_\-\.\/]+$/, path) ->
            add_error(changeset, :path, "contains invalid characters")

          true ->
            changeset
        end
    end
  end

  # Only allow safe content types for static sites
  @allowed_content_types [
    "text/html",
    "text/css",
    "text/javascript",
    "application/javascript",
    "application/json",
    "text/plain",
    "image/png",
    "image/jpeg",
    "image/gif",
    "image/webp",
    "image/svg+xml",
    "image/x-icon",
    "font/woff",
    "font/woff2",
    "font/ttf",
    "font/otf",
    "application/font-woff",
    "application/font-woff2"
  ]

  defp validate_content_type(changeset) do
    case get_change(changeset, :content_type) do
      nil ->
        changeset

      content_type ->
        if content_type in @allowed_content_types do
          changeset
        else
          add_error(changeset, :content_type, "is not allowed for static sites")
        end
    end
  end
end
