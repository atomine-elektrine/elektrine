defmodule Elektrine.ActivityPub.FederationCleanupWorker do
  @moduledoc """
  Retention cleanup for federation-side cache and bookkeeping tables.
  """

  use Oban.Worker,
    queue: :federation_metadata,
    max_attempts: 1,
    priority: 9

  import Ecto.Query

  alias Elektrine.ActivityPub.{Instances, Tombstone}
  alias Elektrine.Repo
  alias Elektrine.Social.{LinkPreview, Message}
  alias Oban.Job

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{
      deliveries: Elektrine.ActivityPub.cleanup_old_deliveries(),
      instances: Instances.cleanup_old_records(),
      tombstones: prune_old_tombstones(),
      link_previews: prune_orphaned_link_previews(),
      completed_jobs: prune_old_completed_oban_jobs()
    }

    :ok
  end

  defp prune_old_tombstones do
    cutoff = DateTime.utc_now() |> DateTime.add(-180, :day)

    {count, _} =
      from(t in Tombstone,
        where: t.received_at < ^cutoff
      )
      |> Repo.delete_all()

    count
  end

  defp prune_orphaned_link_previews do
    cutoff = DateTime.utc_now() |> DateTime.add(-30, :day)

    referenced_ids =
      from(m in Message,
        where: not is_nil(m.link_preview_id),
        select: m.link_preview_id
      )

    {count, _} =
      from(p in LinkPreview,
        where: p.inserted_at < ^cutoff,
        where: p.id not in subquery(referenced_ids)
      )
      |> Repo.delete_all()

    count
  end

  defp prune_old_completed_oban_jobs do
    cutoff = DateTime.utc_now() |> DateTime.add(-6, :hour)

    {count, _} =
      from(j in Job,
        where: j.state == "completed" and j.completed_at < ^cutoff
      )
      |> Repo.delete_all()

    count
  end
end
