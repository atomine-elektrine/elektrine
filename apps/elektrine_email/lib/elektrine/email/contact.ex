defmodule Elektrine.Email.Contact do
  use Ecto.Schema
  import Ecto.Changeset

  schema "contacts" do
    # Original fields
    field :name, :string
    field :email, :string
    field :phone, :string
    field :organization, :string
    field :notes, :string
    field :favorite, :boolean, default: false

    # CardDAV sync fields
    field :uid, :string
    field :etag, :string

    # Name components (vCard N property)
    field :prefix, :string
    field :suffix, :string
    field :nickname, :string
    field :formatted_name, :string
    field :first_name, :string
    field :last_name, :string
    field :middle_name, :string

    # Multiple emails/phones/addresses as JSON arrays
    field :emails, {:array, :map}, default: []
    field :phones, {:array, :map}, default: []
    field :addresses, {:array, :map}, default: []

    # Social and web
    field :urls, {:array, :map}, default: []
    field :social_profiles, {:array, :map}, default: []

    # Important dates
    field :birthday, :date
    field :anniversary, :date

    # Photo
    field :photo_type, :string
    field :photo_data, :string
    field :photo_content_type, :string

    # Work info
    field :title, :string
    field :department, :string
    field :role, :string

    # Categories/tags
    field :categories, {:array, :string}, default: []

    # Location
    field :geo, :map

    # Raw vCard data for round-trip
    field :vcard_data, :string

    # vCard revision timestamp
    field :revision, :utc_datetime

    # PGP/OpenPGP Encryption
    field :pgp_public_key, :string
    field :pgp_key_id, :string
    field :pgp_fingerprint, :string
    # "manual", "wkd", "keyserver"
    field :pgp_key_source, :string
    field :pgp_key_fetched_at, :utc_datetime
    field :pgp_encrypt_by_default, :boolean, default: false

    belongs_to :user, Elektrine.Accounts.User
    belongs_to :group, Elektrine.Email.ContactGroup

    timestamps()
  end

  @doc """
  Basic changeset for simple contact creation/update.
  """
  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [:user_id, :name, :email, :phone, :organization, :notes, :favorite, :group_id])
    |> validate_required([:user_id, :name, :email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> validate_length(:name, max: 255)
    |> validate_length(:email, max: 255)
    |> validate_length(:phone, max: 50)
    |> validate_length(:organization, max: 255)
    |> unique_constraint([:user_id, :email])
  end

  @doc """
  Full changeset for CardDAV with all vCard fields.
  """
  def carddav_changeset(contact, attrs) do
    contact
    |> cast(attrs, [
      :user_id,
      :name,
      :email,
      :phone,
      :organization,
      :notes,
      :favorite,
      :group_id,
      :uid,
      :etag,
      :prefix,
      :suffix,
      :nickname,
      :formatted_name,
      :first_name,
      :last_name,
      :middle_name,
      :emails,
      :phones,
      :addresses,
      :urls,
      :social_profiles,
      :birthday,
      :anniversary,
      :photo_type,
      :photo_data,
      :photo_content_type,
      :title,
      :department,
      :role,
      :categories,
      :geo,
      :vcard_data,
      :revision
    ])
    |> validate_required([:user_id])
    |> ensure_uid()
    |> ensure_etag()
    |> derive_name_fields()
    |> unique_constraint([:user_id, :uid])
    |> unique_constraint([:user_id, :email])
  end

  defp ensure_uid(changeset) do
    case get_field(changeset, :uid) do
      nil -> put_change(changeset, :uid, Elektrine.Email.VCard.generate_uid())
      _ -> changeset
    end
  end

  defp ensure_etag(changeset) do
    # Generate new etag on any change
    if changeset.changes != %{} do
      put_change(changeset, :etag, generate_etag())
    else
      changeset
    end
  end

  defp generate_etag do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp derive_name_fields(changeset) do
    # If name is not set but formatted_name or first/last names are, derive it
    name = get_field(changeset, :name)
    formatted = get_field(changeset, :formatted_name)
    first = get_field(changeset, :first_name)
    last = get_field(changeset, :last_name)

    cond do
      name && name != "" ->
        changeset

      formatted && formatted != "" ->
        put_change(changeset, :name, formatted)

      first || last ->
        derived = [first, last] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
        put_change(changeset, :name, derived)

      true ->
        changeset
    end
  end
end
