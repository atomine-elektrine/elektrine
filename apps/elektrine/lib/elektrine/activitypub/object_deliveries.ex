defmodule Elektrine.ActivityPub.ObjectDeliveries do
  @moduledoc """
  Ledger of inboxes that have been targeted for an ActivityPub object.

  The delivery attempt table can be pruned, but this ledger lets Deletes and
  Updates reach everyone who may have previously received the object.
  """

  import Ecto.Query

  alias Elektrine.ActivityPub.Activity
  alias Elektrine.ActivityPub.Delivery
  alias Elektrine.ActivityPub.ObjectDelivery
  alias Elektrine.Repo

  @doc """
  Records inboxes that have been targeted for an ActivityPub object.
  """
  def record_object_deliveries(object_id, activity_id, inbox_urls)
      when is_binary(object_id) and is_list(inbox_urls) do
    utc_now = DateTime.utc_now() |> DateTime.truncate(:second)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      inbox_urls
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.map(fn inbox_url ->
        %{
          object_id: object_id,
          inbox_url: inbox_url,
          activity_id: activity_id,
          first_seen_at: utc_now,
          last_seen_at: utc_now,
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows == [] do
      {0, nil}
    else
      Repo.insert_all(ObjectDelivery, rows,
        on_conflict: {:replace, [:activity_id, :last_seen_at, :updated_at]},
        conflict_target: [:object_id, :inbox_url]
      )
    end
  end

  def record_object_deliveries(_object_id, _activity_id, _inbox_urls), do: {0, nil}

  @doc """
  Lists every inbox the object has been delivered toward.
  """
  def get_object_delivery_inboxes(object_id) when is_binary(object_id) do
    ObjectDelivery
    |> where([d], d.object_id == ^object_id)
    |> select([d], d.inbox_url)
    |> Repo.all()
  end

  def get_object_delivery_inboxes(_), do: []

  @doc """
  Stamps the object-delivery ledger after a successful delivery attempt.
  """
  def mark_object_delivery_delivered(%Delivery{
        inbox_url: inbox_url,
        activity: %Activity{object_id: object_id}
      })
      when is_binary(object_id) and is_binary(inbox_url) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(d in ObjectDelivery,
      where: d.object_id == ^object_id and d.inbox_url == ^inbox_url
    )
    |> Repo.update_all(set: [last_delivered_at: now, last_seen_at: now])

    :ok
  end

  def mark_object_delivery_delivered(_delivery), do: :ok
end
