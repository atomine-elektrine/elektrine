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
  def handle(%{"object" => object}, actor_uri, _target_user) do
    object_id =
      case object do
        obj when is_binary(obj) -> obj
        %{"id" => id} -> id
        _ -> nil
      end

    if object_id do
      case Messaging.get_message_by_activitypub_id(object_id) do
        nil ->
          {:ok, :unknown_object}

        message ->
          if message.federated && message.remote_actor_id do
            remote_actor = ActivityPub.get_actor_by_uri(actor_uri)

            if remote_actor && message.remote_actor_id == remote_actor.id do
              message
              |> Ecto.Changeset.change(%{
                deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)
              })
              |> Elektrine.Repo.update()

              {:ok, :deleted}
            else
              Logger.warning("Delete attempt from non-owner: #{actor_uri}")
              {:error, :unauthorized}
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
