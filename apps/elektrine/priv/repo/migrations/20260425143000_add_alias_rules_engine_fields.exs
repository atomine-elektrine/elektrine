defmodule Elektrine.Repo.Migrations.AddAliasRulesEngineFields do
  use Ecto.Migration

  def change do
    alter table(:email_aliases) do
      add :catch_all, :boolean, default: false, null: false
      add :delivery_mode, :string, default: "deliver", null: false
      add :auto_label, :string
      add :expires_at, :utc_datetime
      add :last_used_at, :utc_datetime
      add :received_count, :integer, default: 0, null: false
      add :forwarded_count, :integer, default: 0, null: false
    end

    create index(:email_aliases, [:catch_all])
    create index(:email_aliases, [:expires_at])

    create unique_index(:email_aliases, [:user_id, :catch_all, :alias_email],
             where: "catch_all = true"
           )
  end
end
