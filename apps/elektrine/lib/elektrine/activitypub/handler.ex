defmodule Elektrine.ActivityPub.Handler do
  @moduledoc """
  Handles incoming ActivityPub activities.

  This module routes activities to specialized handlers:
  - FollowHandler: Follow, Accept, Reject activities
  - CreateHandler: Create activities for Notes, Pages, Articles, Questions
  - LikeHandler: Like, Dislike, EmojiReact activities
  - AnnounceHandler: Announce (boost/share) activities
  - DeleteHandler: Delete activities
  - UpdateHandler: Update activities
  - BlockHandler: Block activities
  """

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{MRF, ObjectValidator}

  alias Elektrine.ActivityPub.Handlers.{
    AnnounceHandler,
    BlockHandler,
    CreateHandler,
    DeleteHandler,
    FlagHandler,
    FollowHandler,
    LikeHandler,
    UpdateHandler
  }

  @doc """
  Stores a remote post object locally.
  Used when we need to interact with remote posts (like, boost, reply).
  """
  def store_remote_post(post_object, actor_uri) do
    CreateHandler.handle(%{"object" => post_object}, actor_uri, nil)
  end

  @doc """
  Queues an activity for async processing.

  This function validates and saves the activity, then returns immediately.
  The IncomingActivityWorker will process it in the background.

  Returns {:ok, :queued} on success, allowing the inbox endpoint to return 202 Accepted.
  """
  def handle_activity(activity, actor_uri, _target_user) do
    # Check if the instance is blocked
    %URI{host: domain} = URI.parse(actor_uri)

    if ActivityPub.instance_blocked?(domain) do
      {:ok, :blocked}
    else
      # Validate the activity structure first
      case ObjectValidator.validate(activity) do
        {:error, reason} ->
          Logger.warning("Invalid activity from #{actor_uri}: #{reason}")
          {:ok, :invalid}

        {:ok, validated_activity} ->
          # Run MRF policies
          case MRF.filter(validated_activity) do
            {:reject, reason} ->
              Logger.info("MRF rejected activity from #{actor_uri}: #{reason}")
              {:ok, :mrf_rejected}

            {:ok, filtered_activity} ->
              # Save the (possibly modified) activity for async processing
              case ActivityPub.create_activity(%{
                     activity_id: filtered_activity["id"],
                     activity_type: filtered_activity["type"],
                     actor_uri: actor_uri,
                     object_id: get_object_id(filtered_activity),
                     data: filtered_activity,
                     local: false,
                     processed: false
                   }) do
                {:ok, _record} ->
                  # Trigger the worker to process soon (non-blocking)
                  spawn(fn -> Elektrine.ActivityPub.IncomingActivityWorker.process_now() end)
                  {:ok, :queued}

                {:error, %Ecto.Changeset{errors: [activity_id: {"has already been taken", _}]}} ->
                  {:ok, :already_received}

                {:error, changeset} ->
                  Logger.error("Failed to save activity: #{inspect(changeset)}")
                  {:error, :failed_to_save_activity}
              end
          end
      end
    end
  end

  @doc """
  Processes an activity asynchronously (called by IncomingActivityWorker).

  This does the actual work of handling the activity, including HTTP calls
  to fetch actors and objects from remote servers.
  """
  def process_activity_async(activity, actor_uri, target_user) do
    # Check if user has blocked this actor
    if target_user && ActivityPub.user_blocked?(target_user.id, actor_uri) do
      {:ok, :blocked}
    else
      route_activity(activity, actor_uri, target_user)
    end
  end

  # Route activity to the appropriate handler
  defp route_activity(activity, actor_uri, target_user) do
    case activity["type"] do
      "Follow" ->
        FollowHandler.handle(activity, actor_uri, target_user)

      "Accept" ->
        FollowHandler.handle_accept(activity, actor_uri, target_user)

      "Reject" ->
        FollowHandler.handle_reject(activity, actor_uri, target_user)

      "Create" ->
        CreateHandler.handle(activity, actor_uri, target_user)

      "Like" ->
        LikeHandler.handle(activity, actor_uri, target_user)

      "Dislike" ->
        LikeHandler.handle_dislike(activity, actor_uri, target_user)

      "EmojiReact" ->
        LikeHandler.handle_emoji_react(activity, actor_uri, target_user)

      "Announce" ->
        AnnounceHandler.handle(activity, actor_uri, target_user)

      "Undo" ->
        handle_undo(activity, actor_uri, target_user)

      "Delete" ->
        DeleteHandler.handle(activity, actor_uri, target_user)

      "Update" ->
        UpdateHandler.handle(activity, actor_uri, target_user)

      "Block" ->
        BlockHandler.handle(activity, actor_uri, target_user)

      "Flag" ->
        FlagHandler.handle(activity, actor_uri, target_user)

      _ ->
        {:ok, :unhandled}
    end
  end

  # Handle Undo activities by routing to the appropriate handler
  defp handle_undo(%{"object" => object} = _activity, actor_uri, _target_user)
       when is_map(object) do
    case object["type"] do
      "Follow" ->
        FollowHandler.handle_undo(object, actor_uri)

      "Like" ->
        LikeHandler.handle_undo_like(object, actor_uri)

      "Dislike" ->
        LikeHandler.handle_undo_dislike(object, actor_uri)

      "EmojiReact" ->
        LikeHandler.handle_undo_emoji_react(object, actor_uri)

      "Announce" ->
        AnnounceHandler.handle_undo(object, actor_uri)

      "Block" ->
        BlockHandler.handle_undo(object, actor_uri)

      _ ->
        {:ok, :unhandled}
    end
  end

  # Handle Undo when object is a URI string - fetch and process
  defp handle_undo(%{"object" => object_uri} = activity, actor_uri, target_user)
       when is_binary(object_uri) do
    case Elektrine.ActivityPub.Fetcher.fetch_object(object_uri) do
      {:ok, object} when is_map(object) ->
        handle_undo(%{activity | "object" => object}, actor_uri, target_user)

      {:error, _reason} ->
        {:ok, :acknowledged}
    end
  end

  defp handle_undo(_activity, _actor_uri, _target_user), do: {:ok, :unhandled}

  defp get_object_id(%{"object" => object}) when is_binary(object), do: object
  defp get_object_id(%{"object" => %{"id" => id}}), do: id
  defp get_object_id(_), do: nil

  # Legacy functions kept for backwards compatibility

  @doc """
  Extracts local usernames from ActivityPub Mention tags.
  Delegated to CreateHandler for implementation.
  """
  def extract_local_mentions(object) do
    # Keep for backwards compatibility - call internal implementation
    extract_local_mentions_internal(object)
  end

  defp extract_local_mentions_internal(object) do
    case object["tag"] do
      tags when is_list(tags) ->
        tags
        |> Enum.filter(fn tag -> tag["type"] == "Mention" end)
        |> Enum.map(fn tag ->
          case extract_local_username_from_uri(tag["href"]) do
            {:ok, username} -> username
            _ -> nil
          end
        end)
        |> Enum.filter(&(&1 != nil))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp extract_local_username_from_uri(uri) when is_binary(uri) do
    Elektrine.ActivityPub.local_actor_prefixes()
    |> Enum.find_value({:error, :not_local}, fn prefix ->
      if String.starts_with?(uri, prefix) do
        username =
          uri
          |> String.replace_prefix(prefix, "")
          |> String.split(["/", "?", "#"], parts: 2)
          |> List.first()

        if is_binary(username) and username != "" do
          {:ok, username}
        else
          {:error, :not_local}
        end
      else
        nil
      end
    end)
  end

  defp extract_local_username_from_uri(_), do: {:error, :invalid_uri}
end
