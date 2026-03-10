defmodule Elektrine.Messaging.Federation.Maintenance do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.Messaging.{
    FederationEvent,
    FederationOutboxEvent,
    FederationRequestReplay
  }

  alias Elektrine.Messaging.Federation.Config
  alias Elektrine.Repo

  def run_retention(config) when is_list(config) do
    archive_old_events(config)
    prune_old_outbox_rows(config)
    prune_request_replays()
    :ok
  end

  defp archive_old_events(config) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-Config.event_retention_days(config) * 86_400, :second)
      |> DateTime.truncate(:second)

    sql =
      "INSERT INTO messaging_federation_events_archive (\n  protocol_version,\n  event_id,\n  idempotency_key,\n  origin_domain,\n  event_type,\n  stream_id,\n  sequence,\n  payload,\n  received_at,\n  partition_month,\n  inserted_at\n)\nSELECT\n  protocol_version,\n  event_id,\n  idempotency_key,\n  origin_domain,\n  event_type,\n  stream_id,\n  sequence,\n  payload,\n  received_at,\n  date_trunc('month', inserted_at)::date,\n  inserted_at\nFROM messaging_federation_events\nWHERE inserted_at < $1\nON CONFLICT (origin_domain, event_id) DO NOTHING\n"

    _ = Ecto.Adapters.SQL.query(Repo, sql, [cutoff])
    {_deleted, _} = Repo.delete_all(from(e in FederationEvent, where: e.inserted_at < ^cutoff))
    :ok
  end

  defp prune_old_outbox_rows(config) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-Config.outbox_retention_days(config) * 86_400, :second)
      |> DateTime.truncate(:second)

    {_deleted, _} =
      Repo.delete_all(
        from(o in FederationOutboxEvent,
          where: o.updated_at < ^cutoff and o.status in ["delivered", "failed"]
        )
      )

    :ok
  end

  defp prune_request_replays do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {_deleted, _} =
      Repo.delete_all(from(r in FederationRequestReplay, where: r.expires_at < ^now))

    :ok
  end
end
