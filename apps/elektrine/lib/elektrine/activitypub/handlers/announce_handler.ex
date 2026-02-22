defmodule Elektrine.ActivityPub.Handlers.AnnounceHandler do
  @moduledoc """
  Handles Announce (boost/share) ActivityPub activities.
  """

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.Messaging

  @doc """
  Handles an incoming Announce activity.
  """
  def handle(%{"object" => object_uri}, actor_uri, _target_user) when is_binary(object_uri) do
    case get_local_message_from_uri(object_uri) do
      {:ok, message} ->
        # Local post being boosted
        with {:ok, remote_actor} <- ActivityPub.get_or_fetch_actor(actor_uri) do
          case Messaging.create_federated_boost(message.id, remote_actor.id) do
            {:ok, _} ->
              Task.start(fn ->
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
        # Skip activity wrapper URLs that aren't fetchable
        if String.contains?(object_uri, "/activities/") do
          {:ok, :ignored}
        else
          handle_remote_announce(object_uri, actor_uri)
        end
    end
  end

  def handle(%{"object" => object_ref}, actor_uri, target_user) when is_map(object_ref) do
    case normalize_object_id(object_ref) do
      nil -> {:error, :invalid_object}
      object_uri -> handle(%{"object" => object_uri}, actor_uri, target_user)
    end
  end

  @doc """
  Handles Undo Announce activity.
  """
  def handle_undo(%{"object" => object_ref}, actor_uri) do
    object_uri = normalize_object_id(object_ref)

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

  defp handle_remote_announce(object_uri, actor_uri) do
    with {:ok, booster_actor} <- ActivityPub.get_or_fetch_actor(actor_uri),
         {:ok, object} <- Elektrine.ActivityPub.Fetcher.fetch_object(object_uri) do
      {actual_object, original_actor_uri} = unwrap_object(object)

      cond do
        is_nil(actual_object) ->
          {:ok, :ignored}

        actual_object["type"] not in ["Note", "Page", "Article"] ->
          {:ok, :ignored}

        original_actor_uri == actor_uri ->
          {:ok, :ignored}

        true ->
          create_or_boost_post(actual_object, original_actor_uri, booster_actor)
      end
    else
      {:error, reason} ->
        Logger.warning("Failed to fetch announced object #{object_uri}: #{inspect(reason)}")
        {:error, :fetch_failed}
    end
  end

  defp unwrap_object(object) do
    case object["type"] do
      type when type in ["Note", "Page", "Article"] ->
        {object, object["attributedTo"]}

      "Create" ->
        inner_object = object["object"]

        if is_map(inner_object) do
          {inner_object, inner_object["attributedTo"] || object["actor"]}
        else
          case Elektrine.ActivityPub.Fetcher.fetch_object(inner_object) do
            {:ok, fetched} -> {fetched, fetched["attributedTo"]}
            _ -> {nil, nil}
          end
        end

      _ ->
        {nil, nil}
    end
  end

  defp create_or_boost_post(actual_object, original_actor_uri, booster_actor) do
    # Delegate to CreateHandler for the actual post creation
    alias Elektrine.ActivityPub.Handlers.CreateHandler

    case CreateHandler.create_note(actual_object, original_actor_uri) do
      {:ok, :already_exists} ->
        # Skip boost treatment for community distributions and relay actors
        is_distribution = distribution_actor?(booster_actor)

        unless is_distribution do
          ap_id = actual_object["id"]

          case Elektrine.Repo.get_by(Elektrine.Messaging.Message, activitypub_id: ap_id) do
            %{id: message_id} ->
              Messaging.create_federated_boost(message_id, booster_actor.id)

            nil ->
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
            Messaging.create_federated_boost(message.id, booster_actor.id)

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
  end

  defp normalize_object_id(object) when is_binary(object), do: object
  defp normalize_object_id(%{"id" => id}), do: id
  defp normalize_object_id(_), do: nil

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
end
