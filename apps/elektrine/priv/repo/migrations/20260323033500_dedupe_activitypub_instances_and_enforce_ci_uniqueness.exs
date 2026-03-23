defmodule Elektrine.Repo.Migrations.DedupeActivitypubInstancesAndEnforceCiUniqueness do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM activitypub_instances dup
    USING activitypub_instances keep
    WHERE lower(dup.domain) = lower(keep.domain)
      AND dup.id <> keep.id
      AND (
        COALESCE(dup.metadata_updated_at, dup.updated_at, dup.inserted_at, NOW()),
        COALESCE(dup.updated_at, dup.inserted_at, NOW()),
        dup.id
      ) < (
        COALESCE(keep.metadata_updated_at, keep.updated_at, keep.inserted_at, NOW()),
        COALESCE(keep.updated_at, keep.inserted_at, NOW()),
        keep.id
      )
    """)

    execute("""
    DELETE FROM activitypub_instances
    WHERE id IN (
      SELECT id FROM (
        SELECT id,
               ROW_NUMBER() OVER (
                 PARTITION BY lower(domain)
                 ORDER BY
                   COALESCE(metadata_updated_at, updated_at, inserted_at, NOW()) DESC,
                   COALESCE(updated_at, inserted_at, NOW()) DESC,
                   id DESC
               ) AS row_num
        FROM activitypub_instances
      ) ranked
      WHERE ranked.row_num > 1
    )
    """)

    create_if_not_exists unique_index(:activitypub_instances, ["lower(domain)"],
                           name: :activitypub_instances_domain_ci_unique
                         )
  end

  def down do
    drop_if_exists index(:activitypub_instances, ["lower(domain)"],
                     name: :activitypub_instances_domain_ci_unique
                   )
  end
end
