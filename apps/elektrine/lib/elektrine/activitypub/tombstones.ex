defmodule Elektrine.ActivityPub.Tombstones do
  @moduledoc """
  Records and checks remote Delete receipts (tombstones).

  Keeping a tombstone for every remote Delete lets later imports of the same
  object be ignored, matching Mastodon's delete-arrived-first guard.
  """

  import Ecto.Query

  alias Elektrine.ActivityPub.Activity
  alias Elektrine.ActivityPub.Tombstone
  alias Elektrine.Repo

  @doc """
  Records a remote Delete receipt so later imports of the same object can be ignored.
  """
  def record_remote_delete_receipt(activity, actor_uri, object_id)
      when is_map(activity) and is_binary(actor_uri) and is_binary(object_id) do
    canonical_actor_uri = normalize_activitypub_ref(actor_uri)
    canonical_object_id = normalize_activitypub_ref(object_id)

    if is_nil(canonical_actor_uri) or is_nil(canonical_object_id) do
      {:error, :invalid_delete_receipt}
    else
      record_remote_tombstone_row(activity, canonical_actor_uri, canonical_object_id)

      existing_receipt =
        from(a in Activity,
          where:
            a.local == false and a.activity_type == "Delete" and
              a.actor_uri == ^canonical_actor_uri and a.object_id == ^canonical_object_id,
          limit: 1
        )
        |> Repo.one()

      if existing_receipt do
        {:ok, existing_receipt}
      else
        activity_id =
          Map.get(activity, "id") ||
            delete_receipt_activity_id(canonical_actor_uri, canonical_object_id)

        %Activity{}
        |> Activity.changeset(%{
          activity_id: activity_id,
          activity_type: "Delete",
          actor_uri: canonical_actor_uri,
          object_id: canonical_object_id,
          data: activity,
          local: false,
          processed: true,
          processed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()
      end
    end
  end

  def record_remote_delete_receipt(_activity, _actor_uri, _object_id),
    do: {:error, :invalid_delete_receipt}

  @doc """
  Records a remote object tombstone.

  This is an explicit alias for Delete receipts; keeping the name separate makes
  call sites read like Mastodon's delete-arrived-first guard.
  """
  def record_remote_tombstone(activity, actor_uri, object_id),
    do: record_remote_delete_receipt(activity, actor_uri, object_id)

  @doc """
  Returns true when a previously received remote Delete applies to the actor/object pair.
  """
  def remote_delete_recorded?(actor_uri, object_refs) when is_binary(actor_uri) do
    canonical_actor_uri = normalize_activitypub_ref(actor_uri)

    canonical_object_refs =
      object_refs
      |> List.wrap()
      |> Enum.map(&normalize_activitypub_ref/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if is_binary(canonical_actor_uri) and canonical_object_refs != [] do
      tombstone_exists? =
        from(t in Tombstone,
          where: t.actor_uri == ^canonical_actor_uri and t.object_id in ^canonical_object_refs,
          select: 1,
          limit: 1
        )
        |> Repo.exists?()

      tombstone_exists? or
        from(a in Activity,
          where:
            a.local == false and a.activity_type == "Delete" and
              a.actor_uri == ^canonical_actor_uri and a.object_id in ^canonical_object_refs,
          select: 1,
          limit: 1
        )
        |> Repo.exists?()
    else
      false
    end
  end

  def remote_delete_recorded?(_actor_uri, _object_refs), do: false

  @doc """
  Returns true when a remote tombstone exists for the actor/object pair.
  """
  def remote_tombstone_recorded?(actor_uri, object_refs),
    do: remote_delete_recorded?(actor_uri, object_refs)

  defp record_remote_tombstone_row(activity, actor_uri, object_id) do
    received_at = DateTime.utc_now() |> DateTime.truncate(:second)

    %Tombstone{}
    |> Tombstone.changeset(%{
      activity_id: Map.get(activity, "id"),
      actor_uri: actor_uri,
      object_id: object_id,
      data: activity,
      received_at: received_at
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:actor_uri, :object_id]
    )
  end

  defp delete_receipt_activity_id(actor_uri, object_id)
       when is_binary(actor_uri) and is_binary(object_id) do
    digest =
      :crypto.hash(:sha256, actor_uri <> "\n" <> object_id)
      |> Base.encode16(case: :lower)

    "delete-receipt:" <> digest
  end

  defp normalize_activitypub_ref(ref) when is_binary(ref) do
    ref
    |> String.trim()
    |> String.split("#", parts: 2)
    |> hd()
    |> String.split("?", parts: 2)
    |> hd()
    |> String.trim_trailing("/")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_activitypub_ref(_), do: nil
end
