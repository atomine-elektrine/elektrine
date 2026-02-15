defmodule Elektrine.Repo.Migrations.AddReachabilityToInstances do
  use Ecto.Migration

  def change do
    alter table(:activitypub_instances) do
      add(:unreachable_since, :utc_datetime)
      add(:failure_count, :integer, default: 0)
    end

    # Index for querying unreachable instances
    create(
      index(:activitypub_instances, [:unreachable_since], where: "unreachable_since IS NOT NULL")
    )
  end
end
