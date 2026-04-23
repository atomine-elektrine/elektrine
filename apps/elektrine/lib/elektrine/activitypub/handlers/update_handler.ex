defmodule Elektrine.ActivityPub.Handlers.UpdateHandler do
  @moduledoc """
  Handles Update ActivityPub activities for actors and objects.
  """

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Handlers.CreateHandler
  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.Social.Message

  @remote_media_metadata_keys [
    "alt_texts",
    "original_like_count",
    "original_reply_count",
    "original_share_count",
    "inReplyTo",
    "inReplyToAuthor",
    "inReplyToContent",
    "external_link",
    "community_actor_uri"
  ]

  @doc """
  Handles an incoming Update activity.
  """
  def handle(%{"object" => object} = activity, actor_uri, _target_user) when is_map(object) do
    object = inherit_wrapper_fields(activity, object)

    case object["type"] do
      "Person" ->
        refresh_actor(actor_uri, object["id"], :profile_updated)

      "Service" ->
        refresh_actor(actor_uri, object["id"], :profile_updated)

      "Group" ->
        refresh_actor(actor_uri, object["id"], :group_updated)

      type when type in ["Note", "Article", "Page", "Question"] ->
        update_note(object, actor_uri)

      _other_type ->
        {:ok, :unhandled}
    end
  end

  def handle(%{"object" => object_uri} = activity, actor_uri, target_user)
      when is_binary(object_uri) do
    case Elektrine.ActivityPub.Fetcher.fetch_object(object_uri) do
      {:ok, object} when is_map(object) ->
        handle(
          %{activity | "object" => inherit_wrapper_fields(activity, object)},
          actor_uri,
          target_user
        )

      {:ok, _object} ->
        Logger.warning(
          "Failed to fetch Update object #{object_uri}: referenced object was not a map"
        )

        {:error, :update_object_fetch_failed}

      {:error, reason} ->
        Logger.warning("Failed to fetch Update object #{object_uri}: #{inspect(reason)}")
        {:error, :update_object_fetch_failed}
    end
  end

  def handle(_activity, _actor_uri, _target_user) do
    {:ok, :unhandled}
  end

  defp refresh_actor(actor_uri, object_id, success_result) do
    with :ok <- validate_actor_object_match(actor_uri, object_id),
         {:ok, _actor} <- ActivityPub.fetch_and_cache_actor(actor_uri) do
      {:ok, success_result}
    else
      {:error, :actor_mismatch} ->
        Logger.warning(
          "Rejecting Update for #{inspect(object_id)}: object id does not match verified actor #{actor_uri}"
        )

        {:ok, :unauthorized}

      {:error, reason} ->
        Logger.warning("Failed to refresh actor #{actor_uri}: #{inspect(reason)}")
        {:error, :update_actor_fetch_failed}
    end
  end

  defp update_note(object, actor_uri) do
    case Messaging.get_message_by_activitypub_ref(object["id"]) do
      nil ->
        import_unknown_update_object(object, actor_uri)

      message ->
        with :ok <- CreateHandler.validate_object_author(object, actor_uri),
             {:ok, remote_actor} <- fetch_message_actor(actor_uri),
             :ok <- authorize_message_update(message, remote_actor),
             {:ok, _updated_message} <- persist_message_update(message, object, actor_uri) do
          {:ok, :updated}
        else
          {:error, :actor_mismatch} ->
            Logger.warning(
              "Rejecting Update for #{inspect(object["id"])}: object attributedTo does not match verified actor #{actor_uri}"
            )

            {:ok, :unauthorized}

          {:error, :unauthorized} ->
            Logger.warning(
              "Rejecting Update for #{inspect(object["id"])} from non-owner #{actor_uri}"
            )

            {:ok, :unauthorized}

          {:error, :update_actor_fetch_failed} ->
            {:error, :update_actor_fetch_failed}

          {:error, :update_failed} ->
            {:error, :update_failed}
        end
    end
  end

  defp import_unknown_update_object(%{"type" => "Question"} = object, actor_uri) do
    case CreateHandler.create_question(object, actor_uri) do
      {:ok, message} when is_struct(message) -> {:ok, :created_from_update}
      {:ok, result} -> {:ok, result}
      {:error, :actor_mismatch} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp import_unknown_update_object(object, actor_uri) do
    case CreateHandler.create_note(object, actor_uri) do
      {:ok, message} when is_struct(message) -> {:ok, :created_from_update}
      {:ok, result} -> {:ok, result}
      {:error, :actor_mismatch} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_message_actor(actor_uri) do
    case ActivityPub.get_or_fetch_actor(actor_uri) do
      {:ok, remote_actor} ->
        {:ok, remote_actor}

      {:error, reason} ->
        Logger.warning("Failed to fetch Update actor #{actor_uri}: #{inspect(reason)}")
        {:error, :update_actor_fetch_failed}
    end
  end

  defp authorize_message_update(message, remote_actor) do
    if message.remote_actor_id == remote_actor.id do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp persist_message_update(message, %{"type" => "Question"} = object, actor_uri) do
    payload = CreateHandler.build_federated_question_payload(object, actor_uri)

    attrs =
      payload.attrs
      |> Map.take([
        :content,
        :visibility,
        :activitypub_url,
        :media_urls,
        :post_type,
        :like_count,
        :reply_count,
        :share_count,
        :sensitive,
        :content_warning,
        :extracted_hashtags
      ])
      |> Map.put(
        :media_metadata,
        merge_remote_media_metadata(message.media_metadata, payload.attrs.media_metadata)
      )

    message
    |> Message.federated_changeset(attrs)
    |> Ecto.Changeset.put_change(:edited_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
    |> case do
      {:ok, updated_message} ->
        CreateHandler.sync_message_hashtags(updated_message.id, payload.hashtags)

        case CreateHandler.upsert_federated_poll(updated_message.id, object, payload.options) do
          {:ok, _poll} ->
            {:ok, updated_message}

          {:error, reason} ->
            Logger.warning(
              "Updated federated message #{updated_message.id} but failed to sync poll data: #{inspect(reason)}"
            )

            {:error, :update_failed}
        end

      {:error, changeset} ->
        log_update_failure(message.id, changeset)
        {:error, :update_failed}
    end
  end

  defp persist_message_update(message, object, actor_uri) do
    payload = CreateHandler.build_federated_message_payload(object, actor_uri)

    attrs =
      payload.attrs
      |> Map.take([
        :content,
        :title,
        :visibility,
        :activitypub_url,
        :primary_url,
        :media_urls,
        :reply_to_id,
        :quoted_message_id,
        :like_count,
        :reply_count,
        :share_count,
        :sensitive,
        :content_warning,
        :extracted_hashtags
      ])
      |> Map.put(
        :media_metadata,
        merge_remote_media_metadata(message.media_metadata, payload.attrs.media_metadata)
      )
      |> maybe_put_primary_url_from_metadata(message)

    message
    |> Message.federated_changeset(attrs)
    |> Ecto.Changeset.put_change(:edited_at, DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
    |> case do
      {:ok, updated_message} ->
        CreateHandler.sync_message_hashtags(updated_message.id, payload.hashtags)
        {:ok, updated_message}

      {:error, changeset} ->
        log_update_failure(message.id, changeset)
        {:error, :update_failed}
    end
  end

  defp merge_remote_media_metadata(existing_metadata, fresh_metadata) do
    existing_metadata =
      case existing_metadata do
        metadata when is_map(metadata) -> metadata
        _ -> %{}
      end

    fresh_metadata =
      case fresh_metadata do
        metadata when is_map(metadata) -> metadata
        _ -> %{}
      end

    existing_metadata
    |> Map.drop(@remote_media_metadata_keys)
    |> Map.merge(fresh_metadata)
  end

  defp maybe_put_primary_url_from_metadata(attrs, message) when is_map(attrs) do
    cond do
      Elektrine.Strings.present?(attrs[:primary_url]) ->
        attrs

      Elektrine.Strings.present?(message.primary_url) ->
        attrs

      true ->
        case get_in(attrs[:media_metadata] || %{}, ["external_link"]) do
          url when is_binary(url) and url != "" -> Map.put(attrs, :primary_url, url)
          _ -> attrs
        end
    end
  end

  defp log_update_failure(message_id, changeset) do
    Logger.warning(
      "Failed to update federated message #{message_id}: #{inspect(changeset.errors)}"
    )
  end

  defp validate_actor_object_match(actor_uri, nil) when is_binary(actor_uri), do: :ok

  defp validate_actor_object_match(actor_uri, object_id)
       when is_binary(actor_uri) and is_binary(object_id) do
    if normalize_uri(actor_uri) == normalize_uri(object_id) do
      :ok
    else
      {:error, :actor_mismatch}
    end
  end

  defp validate_actor_object_match(_actor_uri, _object_id), do: {:error, :actor_mismatch}

  defp normalize_uri(uri) when is_binary(uri) do
    uri
    |> String.trim()
    |> String.split("#", parts: 2)
    |> hd()
    |> String.split("?", parts: 2)
    |> hd()
    |> String.trim_trailing("/")
  end

  defp normalize_uri(_), do: nil

  defp inherit_wrapper_fields(activity, object) when is_map(activity) and is_map(object) do
    ["to", "cc", "audience", "published"]
    |> Enum.reduce(object, fn field, acc ->
      case {Map.get(acc, field), Map.get(activity, field)} do
        {value, inherited} when value in [nil, ""] and not is_nil(inherited) ->
          Map.put(acc, field, inherited)

        {[], inherited} when not is_nil(inherited) ->
          Map.put(acc, field, inherited)

        _ ->
          acc
      end
    end)
  end

  defp inherit_wrapper_fields(_activity, object), do: object
end
