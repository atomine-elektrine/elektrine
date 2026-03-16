defmodule Elektrine.Repo.Migrations.AddFederatedFieldsToCommunityBans do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE community_bans ALTER COLUMN banned_by_id DROP NOT NULL",
      "ALTER TABLE community_bans ALTER COLUMN banned_by_id SET NOT NULL"
    )

    alter table(:community_bans) do
      add :origin_domain, :string
      add :actor_payload, :map, default: %{}, null: false
      add :metadata, :map, default: %{}, null: false
      add :banned_at_remote, :utc_datetime
      add :updated_at_remote, :utc_datetime
    end

    create index(:community_bans, [:origin_domain])
  end
end
