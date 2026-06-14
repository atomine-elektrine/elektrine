defmodule Elektrine.Repo.Migrations.AddFailingSinceToCustomDomains do
  use Ecto.Migration

  def change do
    alter table(:email_custom_domains) do
      add :failing_since, :utc_datetime
    end

    alter table(:profile_custom_domains) do
      add :failing_since, :utc_datetime
    end
  end
end
