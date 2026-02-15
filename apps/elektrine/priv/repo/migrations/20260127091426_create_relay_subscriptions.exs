defmodule Elektrine.Repo.Migrations.CreateRelaySubscriptions do
  use Ecto.Migration

  def change do
    create table(:activitypub_relay_subscriptions) do
      # The relay actor URI (e.g., https://relay.mastodon.host/actor)
      add :relay_uri, :string, null: false

      # The Follow activity ID we sent
      add :follow_activity_id, :string

      # Status: pending (awaiting Accept), active, rejected, error
      add :status, :string, default: "pending"

      # Cached relay actor info
      add :relay_inbox, :string
      add :relay_name, :string
      add :relay_software, :string

      # Whether we're accepted by the relay
      add :accepted, :boolean, default: false

      # Error details if subscription failed
      add :error_message, :text

      # Who subscribed to this relay
      add :subscribed_by_id, references(:users, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:activitypub_relay_subscriptions, [:relay_uri])
    create index(:activitypub_relay_subscriptions, [:status])
  end
end
