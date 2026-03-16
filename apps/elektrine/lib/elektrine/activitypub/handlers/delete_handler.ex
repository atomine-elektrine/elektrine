defmodule Elektrine.ActivityPub.Handlers.DeleteHandler do
  @moduledoc """
  Handles Delete ActivityPub activities.
  """

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.Messaging

  @doc """
  Handles an incoming Delete activity.
  """
  def handle(%{"object" => object} = activity, actor_uri, _target_user) do
    object_id =
      case object do
        obj when is_binary(obj) -> obj
        %{"id" => id} -> id
        _ -> nil
      end

    if object_id do
      case Messaging.get_message_by_activitypub_ref(object_id) do
        nil ->
          case ActivityPub.record_remote_delete_receipt(activity, actor_uri, object_id) do
            {:ok, _receipt} ->
              {:ok, :delete_receipt_recorded}

            {:error, reason} ->
              Logger.warning(
                "Failed to record Delete receipt for #{inspect(object_id)} from #{actor_uri}: #{inspect(reason)}"
              )

              {:error, :delete_receipt_failed}
          end

        message ->
          if message.federated && message.remote_actor_id do
            remote_actor = ActivityPub.get_actor_by_uri(actor_uri)

            if remote_actor && message.remote_actor_id == remote_actor.id do
              message
              |> Ecto.Changeset.change(%{
                deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)
              })
              |> Elektrine.Repo.update()

              case ActivityPub.record_remote_delete_receipt(activity, actor_uri, object_id) do
                {:ok, _receipt} ->
                  {:ok, :deleted}

                {:error, reason} ->
                  Logger.warning(
                    "Deleted message #{message.id} but failed to persist Delete receipt: #{inspect(reason)}"
                  )

                  {:ok, :deleted}
              end
            else
              Logger.warning("Delete attempt from non-owner: #{actor_uri}")
              {:ok, :unauthorized}
            end
          else
            {:ok, :not_federated_message}
          end
      end
    else
      Logger.warning("Delete activity has no valid object ID")
      {:ok, :invalid_delete}
    end
  end
end
