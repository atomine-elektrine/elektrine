defmodule Elektrine.Repo.Migrations.ScopeMessagingFederationEventIdsByOrigin do
  use Ecto.Migration

  def change do
    drop_if_exists(index(:messaging_federation_events, [:event_id]))

    create(
      unique_index(:messaging_federation_events, [:origin_domain, :event_id],
        name: :messaging_federation_events_origin_event_id_unique
      )
    )

    drop_if_exists(
      index(:messaging_federation_events_archive, [:event_id],
        name: :messaging_federation_events_archive_event_id_unique
      )
    )

    create(
      unique_index(:messaging_federation_events_archive, [:origin_domain, :event_id],
        name: :messaging_federation_events_archive_origin_event_id_unique
      )
    )
  end
end
