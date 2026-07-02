defmodule Elektrine.Repo.Migrations.CreateAccountNotes do
  use Ecto.Migration

  def change do
    create table(:account_notes) do
      add :comment, :text
      add :source_user_id, references(:users, on_delete: :delete_all), null: false
      add :target_user_id, references(:users, on_delete: :delete_all)
      add :target_remote_actor_id, references(:activitypub_actors, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:account_notes, [:source_user_id, :target_user_id],
             where: "target_user_id IS NOT NULL"
           )

    create unique_index(:account_notes, [:source_user_id, :target_remote_actor_id],
             where: "target_remote_actor_id IS NOT NULL"
           )

    create constraint(:account_notes, :account_notes_exactly_one_target,
             check:
               "(target_user_id IS NOT NULL AND target_remote_actor_id IS NULL) OR " <>
                 "(target_user_id IS NULL AND target_remote_actor_id IS NOT NULL)"
           )
  end
end
