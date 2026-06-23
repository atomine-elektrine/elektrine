defmodule Elektrine.Repo.Migrations.CreateProfilePerSiteIdentities do
  use Ecto.Migration

  def change do
    create table(:profile_per_site_identities) do
      add :site_key, :string, null: false
      add :base_domain, :string, null: false
      add :domain, :string, null: false
      add :subject, :string, null: false
      add :did, :string, null: false
      add :email_alias, :string, null: false
      add :display_name, :string
      add :avatar, :string
      add :claims, :map, default: %{}, null: false
      add :enabled, :boolean, default: true, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:profile_per_site_identities, [:user_id])
    create index(:profile_per_site_identities, [:domain])

    create unique_index(:profile_per_site_identities, [:user_id, :base_domain, :site_key],
             name: :profile_per_site_identities_user_base_site_unique
           )
  end
end
