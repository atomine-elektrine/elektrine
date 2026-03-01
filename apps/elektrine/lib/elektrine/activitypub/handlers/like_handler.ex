defmodule Elektrine.ActivityPub.Handlers.LikeHandler do
  @moduledoc """
  Handles Like, Dislike, and EmojiReact ActivityPub activities.
  """

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Fetcher
  alias Elektrine.ActivityPub.Handlers.CreateHandler
  alias Elektrine.Messaging

  @doc """
  Handles an incoming Like activity.
  """
  def handle(%{"object" => object_ref}, actor_uri, _target_user) do
    object_uri = normalize_object_id(object_ref)

    with {:ok, object_uri} when not is_nil(object_uri) <- {:ok, object_uri},
         {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri),
         {:ok, message} <- get_local_message_from_uri(object_uri) do
      case Messaging.create_federated_like(message.id, remote_actor.id) do
        {:ok, _like} ->
          Task.start(fn ->
            Elektrine.Notifications.FederationNotifications.notify_remote_like(
              message.id,
              remote_actor.id
            )
          end)

          {:ok, :liked}

        {:error, reason} ->
          Logger.error("Failed to create like: #{inspect(reason)}")
          {:error, :failed_to_like}
      end
    else
      {:error, :message_not_found} ->
        Logger.debug("Like for unknown message, ignoring")
        {:error, :handle_like_failed}

      error ->
        Logger.warning("Failed to handle like: #{inspect(error)}")
        {:error, :handle_like_failed}
    end
  end

  @doc """
  Handles an incoming Dislike activity (downvote).
  """
  def handle_dislike(%{"object" => object_ref}, actor_uri, _target_user) do
    object_uri = normalize_object_id(object_ref)

    with {:ok, object_uri} when not is_nil(object_uri) <- {:ok, object_uri},
         {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri),
         {:ok, message} <- get_local_message_from_uri(object_uri) do
      case Messaging.create_federated_dislike(message.id, remote_actor.id) do
        {:ok, _dislike} ->
          {:ok, :disliked}

        {:error, reason} ->
          Logger.error("Failed to create dislike: #{inspect(reason)}")
          {:error, :failed_to_dislike}
      end
    else
      {:error, :message_not_found} ->
        Logger.debug("Dislike for unknown message, ignoring")
        {:error, :handle_dislike_failed}

      error ->
        Logger.warning("Failed to handle dislike: #{inspect(error)}")
        {:error, :handle_dislike_failed}
    end
  end

  @doc """
  Handles an incoming EmojiReact activity.
  Supports both standard Unicode emoji and custom emoji with URLs.
  """
  def handle_emoji_react(
        %{"object" => object_ref, "content" => emoji} = activity,
        actor_uri,
        _target_user
      ) do
    object_uri = normalize_object_id(object_ref)
    # Extract custom emoji URL from tag if present (like Akkoma's format)
    emoji_url = extract_emoji_url(activity, emoji)

    with {:ok, object_uri} when not is_nil(object_uri) <- {:ok, object_uri},
         {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri),
         {:ok, message} <- get_or_fetch_message_from_uri(object_uri) do
      case Elektrine.Messaging.Messages.create_federated_emoji_reaction(
             message.id,
             remote_actor.id,
             emoji,
             emoji_url
           ) do
        {:ok, _reaction} ->
          Task.start(fn ->
            Elektrine.Notifications.FederationNotifications.notify_remote_reaction(
              message.id,
              remote_actor.id,
              emoji
            )
          end)

          {:ok, :emoji_reacted}

        {:error, reason} ->
          Logger.error("Failed to create emoji reaction: #{inspect(reason)}")
          {:error, :failed_to_react}
      end
    else
      {:error, :message_not_found} ->
        Logger.debug("EmojiReact for unknown message, ignoring")
        {:error, :handle_emoji_react_failed}

      error ->
        Logger.warning("Failed to handle emoji react: #{inspect(error)}")
        {:error, :handle_emoji_react_failed}
    end
  end

  def handle_emoji_react(_activity, _actor_uri, _target_user), do: {:ok, :unhandled}

  # Extract custom emoji URL from EmojiReact activity tags
  # Format: {"tag": [{"type": "Emoji", "name": ":blobcat:", "icon": {"url": "https://..."}}]}
  defp extract_emoji_url(%{"tag" => tags}, emoji) when is_list(tags) do
    # Find matching emoji tag
    Enum.find_value(tags, fn
      %{"type" => "Emoji", "name" => name, "icon" => %{"url" => url}} ->
        # Match by name (with or without colons)
        clean_name = String.trim(name, ":")
        clean_emoji = String.trim(emoji, ":")
        if clean_name == clean_emoji, do: url, else: nil

      _ ->
        nil
    end)
  end

  defp extract_emoji_url(_, _), do: nil

  @doc """
  Handles Undo Like activity.
  """
  def handle_undo_like(%{"object" => object_ref}, actor_uri) do
    object_uri = normalize_object_id(object_ref)

    with {:ok, object_uri} when not is_nil(object_uri) <- {:ok, object_uri},
         {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri),
         {:ok, message} <- get_local_message_from_uri(object_uri) do
      Messaging.delete_federated_like(message.id, remote_actor.id)
      {:ok, :unliked}
    else
      {:error, :message_not_found} ->
        {:ok, :message_not_found}

      error ->
        Logger.warning("Failed to undo like: #{inspect(error)}")
        {:error, :undo_like_failed}
    end
  end

  @doc """
  Handles Undo Dislike activity.
  """
  def handle_undo_dislike(%{"object" => object_ref}, actor_uri) do
    object_uri = normalize_object_id(object_ref)

    with {:ok, object_uri} when not is_nil(object_uri) <- {:ok, object_uri},
         {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri),
         {:ok, message} <- get_local_message_from_uri(object_uri) do
      Messaging.delete_federated_dislike(message.id, remote_actor.id)
      {:ok, :undisliked}
    else
      {:error, :message_not_found} ->
        {:ok, :message_not_found}

      error ->
        Logger.warning("Failed to undo dislike: #{inspect(error)}")
        {:error, :undo_dislike_failed}
    end
  end

  @doc """
  Handles Undo EmojiReact activity.
  """
  def handle_undo_emoji_react(%{"object" => object_ref, "content" => emoji}, actor_uri)
      when is_binary(emoji) do
    object_uri = normalize_object_id(object_ref)

    with {:ok, object_uri} when not is_nil(object_uri) <- {:ok, object_uri},
         {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri),
         {:ok, message} <- get_local_message_from_uri(object_uri) do
      Elektrine.Messaging.Messages.delete_federated_emoji_reaction(
        message.id,
        remote_actor.id,
        emoji
      )

      {:ok, :emoji_unreacted}
    else
      error ->
        Logger.warning("Failed to undo emoji react: #{inspect(error)}")
        {:error, :undo_emoji_react_failed}
    end
  end

  def handle_undo_emoji_react(%{"object" => _object_ref, "tag" => tags} = object, actor_uri)
      when is_list(tags) do
    # Extract emoji from tag
    emoji =
      Enum.find_value(tags, fn
        %{"type" => "Emoji", "name" => name} -> name
        _ -> nil
      end)

    if emoji do
      handle_undo_emoji_react(Map.put(object, "content", emoji), actor_uri)
    else
      {:ok, :no_emoji_found}
    end
  end

  def handle_undo_emoji_react(_object, actor_uri) do
    Logger.warning("Invalid Undo EmojiReact from #{actor_uri}")
    {:ok, :invalid}
  end

  # Private functions

  defp normalize_object_id(object) when is_binary(object), do: object
  defp normalize_object_id(%{"id" => id}), do: id
  defp normalize_object_id(_), do: nil

  defp get_local_message_from_uri(uri) do
    base_url = ActivityPub.instance_url()

    cond do
      # Format: https://domain/posts/{id}
      String.starts_with?(uri, "#{base_url}/posts/") ->
        id = String.replace_prefix(uri, "#{base_url}/posts/", "")
        get_message_by_id(id)

      # Format: https://domain/users/{username}/posts/{id}
      String.match?(uri, ~r{#{base_url}/users/[^/]+/posts/}) ->
        id = uri |> String.split("/posts/") |> List.last()
        get_message_by_id(id)

      # Check by activitypub_id
      true ->
        case Messaging.get_message_by_activitypub_id(uri) do
          nil -> {:error, :message_not_found}
          message -> {:ok, message}
        end
    end
  end

  defp get_message_by_id(id) do
    case Messaging.get_message(id) do
      nil -> {:error, :message_not_found}
      message -> {:ok, message}
    end
  rescue
    Ecto.Query.CastError -> {:error, :message_not_found}
  end

  # For remote EmojiReact races, try to fetch/cache the target object if we don't
  # already have it locally.
  defp get_or_fetch_message_from_uri(uri) do
    case get_local_message_from_uri(uri) do
      {:ok, message} ->
        {:ok, message}

      {:error, :message_not_found} ->
        with {:ok, object, author_uri} <- fetch_reactable_object(uri),
             :ok <- cache_reactable_object(object, author_uri),
             {:ok, message} <- get_local_message_from_uri(object["id"] || uri) do
          {:ok, message}
        else
          _ -> {:error, :message_not_found}
        end
    end
  end

  defp fetch_reactable_object(uri) do
    with {:ok, object} <- Fetcher.fetch_object(uri),
         {:ok, reactable_object, author_uri} <- normalize_reactable_object(object) do
      {:ok, reactable_object, author_uri}
    end
  end

  # Handles Note/Page/Article directly and Create wrappers with embedded/linked object.
  defp normalize_reactable_object(%{"type" => type} = object)
       when type in ["Note", "Page", "Article"] do
    case normalize_actor_uri(object["attributedTo"]) do
      actor_uri when is_binary(actor_uri) -> {:ok, object, actor_uri}
      _ -> {:error, :missing_author}
    end
  end

  defp normalize_reactable_object(%{"type" => "Create"} = object) do
    creator_uri = normalize_actor_uri(object["actor"])

    case object["object"] do
      %{} = inner_object ->
        inner_with_actor =
          if creator_uri do
            Map.put_new(inner_object, "attributedTo", creator_uri)
          else
            inner_object
          end

        normalize_reactable_object(inner_with_actor)

      inner_uri when is_binary(inner_uri) ->
        with {:ok, fetched_inner} <- Fetcher.fetch_object(inner_uri) do
          inner_with_actor =
            if creator_uri do
              Map.put_new(fetched_inner, "attributedTo", creator_uri)
            else
              fetched_inner
            end

          normalize_reactable_object(inner_with_actor)
        end

      _ ->
        {:error, :unsupported_object}
    end
  end

  defp normalize_reactable_object(_), do: {:error, :unsupported_object}

  defp cache_reactable_object(object, author_uri) do
    case CreateHandler.create_note(object, author_uri) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_actor_uri(uri) when is_binary(uri), do: uri
  defp normalize_actor_uri([head | _]), do: normalize_actor_uri(head)
  defp normalize_actor_uri(%{"id" => id}) when is_binary(id), do: id
  defp normalize_actor_uri(_), do: nil
end
