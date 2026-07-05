defmodule Elektrine.Repo.Migrations.KairoDedupAndProjectNilify do
  use Ecto.Migration

  def up do
    # Remove any duplicate ingests (keep the oldest row) so the unique index
    # can be created, then enforce dedup at the database level.
    execute """
    DELETE FROM kairo_sources a
    USING kairo_sources b
    WHERE a.user_id = b.user_id
      AND a.raw_hash = b.raw_hash
      AND a.raw_hash IS NOT NULL
      AND a.id > b.id
    """

    drop index(:kairo_sources, [:raw_hash])

    create unique_index(:kairo_sources, [:user_id, :raw_hash], where: "raw_hash IS NOT NULL")

    # Deleting a project should return its sources to the inbox, not destroy
    # them - the sources are the durable substrate, projects are just grouping.
    execute "ALTER TABLE kairo_sources DROP CONSTRAINT kairo_sources_project_id_fkey"

    alter table(:kairo_sources) do
      modify :project_id, references(:kairo_projects, on_delete: :nilify_all)
    end
  end

  def down do
    execute "ALTER TABLE kairo_sources DROP CONSTRAINT kairo_sources_project_id_fkey"

    alter table(:kairo_sources) do
      modify :project_id, references(:kairo_projects, on_delete: :delete_all)
    end

    drop index(:kairo_sources, [:user_id, :raw_hash])
    create index(:kairo_sources, [:raw_hash])
  end
end
