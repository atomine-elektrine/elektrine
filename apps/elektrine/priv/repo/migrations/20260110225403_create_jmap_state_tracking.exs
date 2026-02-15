defmodule Elektrine.Repo.Migrations.CreateJmapStateTracking do
  use Ecto.Migration

  def change do
    create table(:jmap_state_tracking) do
      add :mailbox_id, references(:mailboxes, on_delete: :delete_all), null: false
      add :entity_type, :string, null: false
      add :state_counter, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:jmap_state_tracking, [:mailbox_id, :entity_type])
  end
end
