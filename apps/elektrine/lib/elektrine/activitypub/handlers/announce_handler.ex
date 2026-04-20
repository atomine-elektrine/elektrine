defmodule Elektrine.ActivityPub.Handlers.AnnounceHandler do
  @moduledoc """
  Handles Announce (boost/share) ActivityPub activities.
  """

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.Async
  alias Elektrine.Messaging

  @doc """
  Handles an incoming Announce activity.
  """
  def handle(%{"object" => object_uri} = activity, actor_uri, _target_user)
      when is_binary(object_uri) do
    activity_id = activity["id"]

    case get_local_message_from_uri(object_uri) do
      {:ok, message} ->
        # Local post being boosted
        with {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri) do
          case Messaging.create_federated_boost(message.id, remote_actor.id, activity_id) do
            {:ok, _} ->
              Async.run(fn ->
                Elektrine.Notifications.FederationNotifications.notify_remote_announce(
                  message.id,
                  remote_actor.id
                )
              end)

              {:ok, :announced}

            {:error, reason} ->
              Logger.error("Failed to create boost record: #{inspect(reason)}")
              {:error, :failed_to_boost}
          end
        end

      {:error, :message_not_found} ->
        handle_remote_announce(object_uri, actor_uri, activity_id)
    end
  end

  def handle(%{"object" => objects}, actor_uri, target_user) when is_list(objects) do
    {any_ok?, any_announced?, first_error} =
      Enum.reduce(objects, {false, false, nil}, fn object_ref,
                                                   {any_ok?, any_announced?, first_error} ->
        case handle(%{"object" => object_ref}, actor_uri, target_user) do
          {:ok, result} ->
            announced? = result in [:announced, :unannounced]
            {true, any_announced? || announced?, first_error}

          {:error, reason} ->
            Logger.warning("Failed to process item in Announce object list: #{inspect(reason)}")
            {any_ok?, any_announced?, first_error || reason}
        end
      end)

    cond do
      any_announced? -> {:ok, :announced}
      any_ok? -> {:ok, :ignored}
      is_atom(first_error) -> {:error, first_error}
      true -> {:ok, :ignored}
    end
  end

  def handle(%{"object" => object_ref}, actor_uri, target_user) when is_map(object_ref) do
    case extract_target_object_uri(object_ref) do
      nil -> {:error, :invalid_object}
      object_uri -> handle(%{"object" => object_uri}, actor_uri, target_user)
    end
  end

  @doc """
  Handles Undo Announce activity.
  """
  def handle_undo(%{"object" => object_ref}, actor_uri) do
    object_uri = extract_target_object_uri(object_ref)

    with {:ok, object_uri} when not is_nil(object_uri) <- {:ok, object_uri},
         {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri),
         {:ok, message} <- get_local_message_from_uri(object_uri) do
      Messaging.delete_federated_boost(message.id, remote_actor.id)
      {:ok, :unannounced}
    else
      {:error, :message_not_found} ->
        {:ok, :message_not_found}

      error ->
        Logger.warning("Failed to undo announce: #{inspect(error)}")
        {:error, :undo_announce_failed}
    end
  end

  # Private functions

  defp handle_remote_announce(object_uri, actor_uri, announce_activity_id) do
    with {:ok, booster_actor} <- ActivityPub.get_or_fetch_actor(actor_uri),
         {:ok, object} <- Elektrine.ActivityPub.Fetcher.fetch_object(object_uri),
         {:ok, {actual_object, original_actor_uri}} <- unwrap_object(object) do
      cond do
        is_nil(actual_object) ->
          {:ok, :ignored}

        actual_object["type"] not in ["Note", "Page", "Article"] ->
          {:ok, :ignored}

        !is_binary(original_actor_uri) ->
          {:ok, :ignored}

        original_actor_uri == actor_uri ->
          {:ok, :ignored}

        true ->
          create_or_boost_post(
            actual_object,
            original_actor_uri,
            booster_actor,
            announce_activity_id
          )
      end
    else
      {:error, :not_found} ->
        if remote_object_uri?(object_uri) do
          {:ok, :ignored}
        else
          {:error, :announce_object_fetch_failed}
        end

      {:error, :nested_fetch_failed} ->
        {:error, :announce_object_fetch_failed}

      {:error, reason} ->
        if ignorable_remote_activity_wrapper_fetch_failure?(object_uri, reason) do
          Logger.debug(
            "Ignoring remote Announce wrapper #{object_uri} after fetch failure: #{inspect(reason)}"
          )

          {:ok, :ignored}
        else
          Logger.warning("Failed to fetch announced object #{object_uri}: #{inspect(reason)}")
          {:error, :announce_object_fetch_failed}
        end
    end
  end

  defp unwrap_object(object, depth \\ 0)
  defp unwrap_object(_object, depth) when depth > 4, do: {:ok, {nil, nil}}

  defp unwrap_object(object, depth) do
    case object["type"] do
      type when type in ["Note", "Page", "Article"] ->
        {:ok, {object, object["attributedTo"]}}

      "Create" ->
        inner_object = object["object"]

        if is_map(inner_object) do
          inherited_object = inherit_wrapper_fields(object, inner_object)
          {:ok, {inherited_object, inherited_object["attributedTo"] || object["actor"]}}
        else
          case Elektrine.ActivityPub.Fetcher.fetch_object(inner_object) do
            {:ok, fetched} ->
              inherited_object = inherit_wrapper_fields(object, fetched)

              with {:ok, {resolved, actor_uri}} <- unwrap_object(inherited_object, depth + 1) do
                {:ok,
                 {resolved, actor_uri || inherited_object["attributedTo"] || object["actor"]}}
              end

            {:error, reason} ->
              Logger.warning(
                "Failed to fetch nested announced object #{inspect(inner_object)}: #{inspect(reason)}"
              )

              {:error, :nested_fetch_failed}
          end
        end

      "Announce" ->
        unwrap_announced_object(object["object"], object["actor"], depth + 1)

      _ ->
        {:ok, {nil, nil}}
    end
  end

  defp unwrap_announced_object(object_ref, fallback_actor_uri, depth) when is_map(object_ref) do
    with {:ok, {resolved, actor_uri}} <- unwrap_object(object_ref, depth) do
      {:ok, {resolved, actor_uri || fallback_actor_uri}}
    end
  end

  defp unwrap_announced_object(object_ref, fallback_actor_uri, depth)
       when is_binary(object_ref) do
    case Elektrine.ActivityPub.Fetcher.fetch_object(object_ref) do
      {:ok, fetched} ->
        with {:ok, {resolved, actor_uri}} <- unwrap_object(fetched, depth) do
          {:ok, {resolved, actor_uri || fallback_actor_uri}}
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to fetch nested announced object #{inspect(object_ref)}: #{inspect(reason)}"
        )

        {:error, :nested_fetch_failed}
    end
  end

  defp unwrap_announced_object(_object_ref, _fallback_actor_uri, _depth), do: {:ok, {nil, nil}}

  defp create_or_boost_post(
         actual_object,
         original_actor_uri,
         booster_actor,
         announce_activity_id
       ) do
    # Delegate to CreateHandler for the actual post creation
    alias Elektrine.ActivityPub.Handlers.CreateHandler

    create_opts =
      if booster_actor.actor_type == "Group" do
        [fallback_community_uri: booster_actor.uri]
      else
        []
      end

    with :ok <- CreateHandler.validate_object_author(actual_object, original_actor_uri),
         false <-
           ActivityPub.remote_delete_recorded?(original_actor_uri, [
             actual_object["id"],
             actual_object["url"]
           ]) do
      case CreateHandler.create_note(actual_object, original_actor_uri, create_opts) do
        {:ok, :already_exists} ->
          # Skip boost treatment for community distributions and relay actors
          is_distribution = distribution_actor?(booster_actor)

          unless is_distribution do
            ap_id = actual_object["id"]

            case Elektrine.Repo.get_by(Elektrine.Messaging.Message, activitypub_id: ap_id) do
              %{id: message_id, deleted_at: nil} ->
                Messaging.create_federated_boost(
                  message_id,
                  booster_actor.id,
                  announce_activity_id
                )

              nil ->
                :ok

              _deleted_message ->
                :ok
            end
          end

          {:ok, :announced}

        {:ok, message} when is_struct(message) ->
          # Skip boost treatment for community distributions and relay actors
          is_distribution = distribution_actor?(booster_actor)

          updated_msg =
            if is_distribution do
              message
            else
              Messaging.create_federated_boost(message.id, booster_actor.id, announce_activity_id)

              case Elektrine.Messaging.Messages.update_message_metadata(message, %{
                     media_metadata:
                       Map.merge(message.media_metadata || %{}, %{
                         "boosted_by" => %{
                           "username" => booster_actor.username,
                           "domain" => booster_actor.domain,
                           "display_name" => booster_actor.display_name,
                           "avatar_url" => booster_actor.avatar_url
                         }
                       })
                   }) do
                {:ok, updated} -> updated
                {:error, _} -> message
              end
            end

          # Reload with associations for broadcasting
          reloaded =
            Elektrine.Repo.preload(
              updated_msg,
              [:remote_actor, :sender, :link_preview, :hashtags],
              force: true
            )

          Phoenix.PubSub.broadcast(
            Elektrine.PubSub,
            "timeline:public",
            {:new_public_post, reloaded}
          )

          {:ok, :announced}

        error ->
          error
      end
    else
      true ->
        {:ok, :ignored_deleted_object}

      {:error, :actor_mismatch} ->
        Logger.warning(
          "Rejecting Announce for #{inspect(actual_object["id"])}: object attributedTo does not match announced actor #{original_actor_uri}"
        )

        {:ok, :unauthorized}
    end
  end

  defp extract_target_object_uri(object) when is_binary(object), do: object
  defp extract_target_object_uri(%{"id" => id}) when is_binary(id), do: id

  defp extract_target_object_uri(%{"object" => object_ref}) do
    extract_target_object_uri(object_ref)
  end

  defp extract_target_object_uri(_), do: nil

  # Check if actor is a distribution actor (relay or community group)
  # These actors relay/distribute content, not boost it
  defp distribution_actor?(actor) do
    cond do
      # Community/Group actors distribute content
      actor.actor_type == "Group" ->
        true

      # Relay actors (Application type with relay in URI)
      actor.actor_type == "Application" && relay_uri?(actor.uri) ->
        true

      # Service actors that are relays
      actor.actor_type == "Service" && relay_uri?(actor.uri) ->
        true

      true ->
        false
    end
  end

  defp relay_uri?(uri) when is_binary(uri) do
    uri_lower = String.downcase(uri)

    String.contains?(uri_lower, "/relay") ||
      String.contains?(uri_lower, "relay.") ||
      (String.ends_with?(uri_lower, "/actor") && String.contains?(uri_lower, "relay"))
  end

  defp relay_uri?(_), do: false

  defp remote_object_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) and host != "" ->
        String.downcase(host) != String.downcase(ActivityPub.instance_domain())

      _ ->
        false
    end
  end

  defp remote_object_uri?(_), do: false

  defp ignorable_remote_activity_wrapper_fetch_failure?(uri, reason)
       when reason in [:fetch_failed, :http_error, :backoff, :not_found, :unsafe_url] do
    remote_activity_wrapper_uri?(uri)
  end

  defp ignorable_remote_activity_wrapper_fetch_failure?(_, _), do: false

  defp remote_activity_wrapper_uri?(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host, path: path}
      when is_binary(host) and host != "" and is_binary(path) and path != "" ->
        String.downcase(host) != String.downcase(ActivityPub.instance_domain()) &&
          Regex.match?(~r{/(?:activity|activities)(?:/|$)}, String.downcase(path))

      _ ->
        false
    end
  end

  defp remote_activity_wrapper_uri?(_), do: false

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

  defp get_local_message_from_uri(uri) do
    base_url = ActivityPub.instance_url()

    cond do
      String.starts_with?(uri, "#{base_url}/posts/") ->
        id = String.replace_prefix(uri, "#{base_url}/posts/", "")
        get_message_by_id(id)

      String.match?(uri, ~r{#{base_url}/users/[^/]+/posts/}) ->
        id = uri |> String.split("/posts/") |> List.last()
        get_message_by_id(id)

      true ->
        case Messaging.get_message_by_activitypub_ref(uri) do
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
end
