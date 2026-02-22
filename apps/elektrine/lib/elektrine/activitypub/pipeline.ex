defmodule Elektrine.ActivityPub.Pipeline do
  @moduledoc "Formal pipeline for processing ActivityPub activities.\n\nImplements a structured flow for incoming and outgoing activities:\n1. Validate - Validate activity structure and content\n2. MRF - Apply Message Rewrite Facility policies\n3. Persist - Save to database within a transaction\n4. Side Effects - Handle notifications, broadcasts, etc.\n5. Federate - Deliver to remote instances (for local activities)\n\nAll operations are wrapped in a database transaction for atomicity.\n"
  require Logger
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{MRF, ObjectValidator, SideEffects}
  alias Elektrine.Repo

  alias Elektrine.ActivityPub.Handlers.{
    AnnounceHandler,
    BlockHandler,
    CreateHandler,
    DeleteHandler,
    FollowHandler,
    LikeHandler,
    UpdateHandler
  }

  @type pipeline_result :: {:ok, map()} | {:error, atom()} | {:reject, String.t()}
  @doc "Processes an incoming activity through the full pipeline.\nWraps all operations in a transaction for atomicity.\n"
  @spec process_incoming(map(), String.t(), map() | nil) :: pipeline_result()
  def process_incoming(activity, actor_uri, target_user) do
    Repo.transaction(fn ->
      with {:ok, activity} <- validate(activity),
           {:ok, activity} <- apply_mrf(activity, actor_uri),
           {:ok, result} <- handle_activity(activity, actor_uri, target_user),
           :ok <- handle_side_effects(activity, actor_uri, result) do
        result
      else
        {:reject, reason} -> Repo.rollback({:rejected, reason})
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  @doc "Processes an outgoing activity (created locally).\nValidates, persists, and queues for federation.\n"
  @spec process_outgoing(map(), map()) :: pipeline_result()
  def process_outgoing(activity, user) do
    Repo.transaction(fn ->
      with {:ok, activity} <- validate(activity),
           {:ok, activity} <- apply_mrf(activity, ActivityPub.instance_url()),
           {:ok, result} <- persist_local_activity(activity, user),
           :ok <- queue_federation(activity, user) do
        result
      else
        {:reject, reason} -> Repo.rollback({:rejected, reason})
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  @doc "Stage 1: Validate the activity structure.\n"
  def validate(activity) do
    case ObjectValidator.validate(activity) do
      {:ok, validated} -> {:ok, validated}
      {:error, reason} -> {:error, {:validation_failed, reason}}
    end
  end

  @doc "Stage 2: Apply MRF policies.\n"
  def apply_mrf(activity, actor_uri) do
    case MRF.filter(activity) do
      {:ok, filtered} ->
        {:ok, filtered}

      {:reject, reason} ->
        Logger.info("Pipeline: MRF rejected activity from #{actor_uri}: #{reason}")
        {:reject, reason}
    end
  end

  @doc "Stage 3: Handle the activity based on type.\nRoutes to the appropriate handler module.\n"
  def handle_activity(%{"type" => "Follow"} = activity, actor_uri, target_user) do
    FollowHandler.handle(activity, actor_uri, target_user)
  end

  def handle_activity(%{"type" => "Accept"} = activity, actor_uri, target_user) do
    FollowHandler.handle_accept(activity, actor_uri, target_user)
  end

  def handle_activity(%{"type" => "Reject"} = activity, actor_uri, target_user) do
    FollowHandler.handle_reject(activity, actor_uri, target_user)
  end

  def handle_activity(%{"type" => "Create"} = activity, actor_uri, target_user) do
    CreateHandler.handle(activity, actor_uri, target_user)
  end

  def handle_activity(%{"type" => "Like"} = activity, actor_uri, target_user) do
    LikeHandler.handle(activity, actor_uri, target_user)
  end

  def handle_activity(%{"type" => "Dislike"} = activity, actor_uri, target_user) do
    LikeHandler.handle_dislike(activity, actor_uri, target_user)
  end

  def handle_activity(%{"type" => "EmojiReact"} = activity, actor_uri, target_user) do
    LikeHandler.handle_emoji_react(activity, actor_uri, target_user)
  end

  def handle_activity(%{"type" => "Announce"} = activity, actor_uri, target_user) do
    AnnounceHandler.handle(activity, actor_uri, target_user)
  end

  def handle_activity(%{"type" => "Undo"} = activity, actor_uri, target_user) do
    handle_undo(activity, actor_uri, target_user)
  end

  def handle_activity(%{"type" => "Delete"} = activity, actor_uri, target_user) do
    DeleteHandler.handle(activity, actor_uri, target_user)
  end

  def handle_activity(%{"type" => "Update"} = activity, actor_uri, target_user) do
    UpdateHandler.handle(activity, actor_uri, target_user)
  end

  def handle_activity(%{"type" => "Block"} = activity, actor_uri, target_user) do
    BlockHandler.handle(activity, actor_uri, target_user)
  end

  def handle_activity(_activity, _actor_uri, _target_user) do
    {:ok, :unhandled}
  end

  @doc "Stage 4: Handle side effects after main processing.\n"
  def handle_side_effects(activity, actor_uri, result) do
    SideEffects.handle(activity, actor_uri, result)
    :ok
  rescue
    e ->
      Logger.warning("Pipeline: Side effect error: #{inspect(e)}")
      :ok
  end

  defp handle_undo(%{"object" => object} = _activity, actor_uri, _target_user)
       when is_map(object) do
    case object["type"] do
      "Follow" -> FollowHandler.handle_undo(object, actor_uri)
      "Like" -> LikeHandler.handle_undo_like(object, actor_uri)
      "Dislike" -> LikeHandler.handle_undo_dislike(object, actor_uri)
      "EmojiReact" -> LikeHandler.handle_undo_emoji_react(object, actor_uri)
      "Announce" -> AnnounceHandler.handle_undo(object, actor_uri)
      "Block" -> BlockHandler.handle_undo(object, actor_uri)
      _ -> {:ok, :unhandled}
    end
  end

  defp handle_undo(%{"object" => object_uri}, actor_uri, target_user)
       when is_binary(object_uri) do
    case ActivityPub.Fetcher.fetch_object(object_uri) do
      {:ok, object} when is_map(object) ->
        handle_undo(%{"object" => object}, actor_uri, target_user)

      {:error, _} ->
        {:ok, :acknowledged}
    end
  end

  defp handle_undo(_, _, _) do
    {:ok, :unhandled}
  end

  defp persist_local_activity(activity, user) do
    case ActivityPub.create_activity(%{
           activity_id: activity["id"],
           activity_type: activity["type"],
           actor_uri: activity["actor"],
           object_id: get_object_id(activity),
           data: activity,
           local: true,
           processed: true,
           internal_user_id: user.id
         }) do
      {:ok, record} -> {:ok, record}
      {:error, changeset} -> {:error, {:persist_failed, changeset}}
    end
  end

  defp queue_federation(activity, user) do
    case Elektrine.ActivityPub.Publisher.publish_async(activity, user) do
      :ok -> :ok
      {:error, reason} -> {:error, {:federation_failed, reason}}
    end
  rescue
    _ -> :ok
  end

  defp get_object_id(%{"object" => object}) when is_binary(object) do
    object
  end

  defp get_object_id(%{"object" => %{"id" => id}}) do
    id
  end

  defp get_object_id(_) do
    nil
  end

  defp normalize_result({:ok, result}) do
    {:ok, result}
  end

  defp normalize_result({:error, {:rejected, reason}}) do
    {:reject, reason}
  end

  defp normalize_result({:error, reason}) do
    {:error, reason}
  end
end
