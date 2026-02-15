defmodule Elektrine.Repo.Migrations.AddNodeinfoToInstances do
  use Ecto.Migration

  def change do
    alter table(:activitypub_instances) do
      add :nodeinfo, :map, default: %{}
      add :favicon, :string
      add :metadata_updated_at, :utc_datetime
    end
  end
end
