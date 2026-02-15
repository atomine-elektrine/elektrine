defmodule Elektrine.PasswordManager.VaultEntry do
  @moduledoc """
  Schema for encrypted password vault entries.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Elektrine.Accounts.User

  schema "password_vault_entries" do
    field :title, :string
    field :login_username, :string
    field :website, :string
    field :encrypted_password, :map
    field :encrypted_notes, :map

    # Virtual fields used when revealing decrypted entry data.
    field :password, :string, virtual: true
    field :notes, :string, virtual: true

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for validating plaintext form input before encryption.
  """
  def form_changeset(vault_entry, attrs) do
    vault_entry
    |> cast(attrs, [:title, :login_username, :website, :password, :notes, :user_id])
    |> normalize_string(:title)
    |> normalize_string(:login_username)
    |> normalize_string(:website)
    |> normalize_string(:notes)
    |> empty_to_nil(:login_username)
    |> empty_to_nil(:website)
    |> empty_to_nil(:notes)
    |> validate_required([:title, :password, :user_id])
    |> validate_length(:title, max: 120)
    |> validate_length(:login_username, max: 255)
    |> validate_length(:website, max: 255)
    |> validate_length(:password, max: 1024)
    |> validate_length(:notes, max: 10_000)
    |> validate_website()
  end

  @doc """
  Changeset for persisting encrypted vault entries.
  """
  def create_changeset(vault_entry, attrs) do
    vault_entry
    |> cast(attrs, [
      :title,
      :login_username,
      :website,
      :encrypted_password,
      :encrypted_notes,
      :user_id
    ])
    |> validate_required([:title, :encrypted_password, :user_id])
    |> validate_length(:title, max: 120)
    |> validate_length(:login_username, max: 255)
    |> validate_length(:website, max: 255)
    |> validate_website()
    |> foreign_key_constraint(:user_id)
  end

  defp validate_website(changeset) do
    case get_field(changeset, :website) do
      nil ->
        changeset

      website ->
        if valid_website?(website) do
          changeset
        else
          add_error(changeset, :website, "must start with http:// or https://")
        end
    end
  end

  defp valid_website?(website) when is_binary(website) do
    uri = URI.parse(website)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  defp normalize_string(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.trim(value)
      value -> value
    end)
  end

  defp empty_to_nil(changeset, field) do
    case get_change(changeset, field) do
      "" -> put_change(changeset, field, nil)
      _ -> changeset
    end
  end
end
