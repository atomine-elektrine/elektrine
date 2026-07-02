defmodule Elektrine.Repo.Migrations.CreateSocialThreadMutes do
  use Ecto.Migration

  def change do
    create table(:social_thread_mutes) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :thread_key, :text, null: false
      add :message_id, references(:social_messages, on_delete: :delete_all)

      timestamps()
    end

    create unique_index(:social_thread_mutes, [:user_id, :thread_key],
             name: :social_thread_mutes_user_thread_unique
           )

    create index(:social_thread_mutes, [:message_id])
  end
end
