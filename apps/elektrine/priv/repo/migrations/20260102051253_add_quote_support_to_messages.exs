defmodule Elektrine.Repo.Migrations.AddQuoteSupportToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # Reference to the quoted message (quote posts)
      add :quoted_message_id, references(:messages, on_delete: :nilify_all)
      # Track quote count on original posts
      add :quote_count, :integer, default: 0
    end

    # Index for looking up quotes of a message
    create index(:messages, [:quoted_message_id])

    # Table to track remote quotes (from federated servers)
    create table(:federated_quotes) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :remote_actor_id, references(:activitypub_actors, on_delete: :delete_all), null: false
      add :activitypub_id, :string, null: false

      timestamps()
    end

    create unique_index(:federated_quotes, [:message_id, :remote_actor_id])
    create index(:federated_quotes, [:remote_actor_id])
    create unique_index(:federated_quotes, [:activitypub_id])
  end
end
