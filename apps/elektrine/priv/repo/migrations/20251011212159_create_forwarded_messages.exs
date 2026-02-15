defmodule Elektrine.Repo.Migrations.CreateForwardedMessages do
  use Ecto.Migration

  def change do
    create table(:forwarded_messages) do
      add :message_id, :string
      add :from_address, :string
      add :subject, :string
      add :original_recipient, :string
      add :final_recipient, :string
      add :forwarding_chain, :jsonb
      add :total_hops, :integer
      add :alias_id, references(:email_aliases, on_delete: :nothing)

      timestamps()
    end

    create index(:forwarded_messages, [:original_recipient])
    create index(:forwarded_messages, [:final_recipient])
    create index(:forwarded_messages, [:alias_id])
    create index(:forwarded_messages, [:inserted_at])
  end
end
