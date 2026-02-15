defmodule Elektrine.Repo.Migrations.ExtendContactsForCarddav do
  use Ecto.Migration

  def change do
    alter table(:contacts) do
      # CardDAV sync fields
      # vCard UID for CardDAV
      add :uid, :string
      # Entity tag for sync
      add :etag, :string

      # Name components (vCard N property)
      # Mr., Dr., etc.
      add :prefix, :string
      # Jr., III, etc.
      add :suffix, :string
      add :nickname, :string
      # vCard FN property
      add :formatted_name, :string
      add :first_name, :string
      add :last_name, :string
      add :middle_name, :string

      # Multiple emails/phones/addresses stored as JSON arrays
      # Format: [%{type: "work", value: "email@example.com", primary: true}, ...]
      add :emails, {:array, :map}, default: []
      add :phones, {:array, :map}, default: []
      add :addresses, {:array, :map}, default: []

      # Social and web
      # [%{type: "home", value: "https://..."}]
      add :urls, {:array, :map}, default: []
      # [%{type: "twitter", value: "@handle"}]
      add :social_profiles, {:array, :map}, default: []

      # Important dates
      add :birthday, :date
      add :anniversary, :date

      # Photo
      # "url", "base64", "binary"
      add :photo_type, :string
      # Base64 encoded photo or URL
      add :photo_data, :text
      # "image/jpeg", "image/png", etc.
      add :photo_content_type, :string

      # Work info
      # Job title
      add :title, :string
      add :department, :string
      add :role, :string

      # Categories/tags (separate from groups)
      add :categories, {:array, :string}, default: []

      # Location
      # %{latitude: 0.0, longitude: 0.0}
      add :geo, :map

      # Raw vCard data for faithful round-trip
      add :vcard_data, :text

      # vCard revision timestamp
      add :revision, :utc_datetime
    end

    # Index for CardDAV lookups
    create unique_index(:contacts, [:user_id, :uid])
    create index(:contacts, [:uid])

    # Add addressbook sync token to users
    alter table(:users) do
      add :addressbook_ctag, :string
    end
  end
end
