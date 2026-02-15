defmodule Elektrine.ActivityPub.Handlers.UpdateHandler do
  @moduledoc """
  Handles Update ActivityPub activities for actors and objects.
  """

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.Messaging

  @doc """
  Handles an incoming Update activity.
  """
  def handle(%{"object" => object}, actor_uri, _target_user) when is_map(object) do
    case object["type"] do
      "Person" ->
        ActivityPub.fetch_and_cache_actor(actor_uri)
        {:ok, :profile_updated}

      "Service" ->
        ActivityPub.fetch_and_cache_actor(actor_uri)
        {:ok, :profile_updated}

      "Group" ->
        group_uri = object["id"]

        if group_uri do
          ActivityPub.fetch_and_cache_actor(group_uri)
          {:ok, :group_updated}
        else
          {:ok, :ignored}
        end

      type when type in ["Note", "Article", "Page", "Question"] ->
        update_note(object, actor_uri)

      _other_type ->
        {:ok, :unhandled}
    end
  end

  def handle(%{"object" => object_uri}, actor_uri, target_user) when is_binary(object_uri) do
    case Elektrine.ActivityPub.Fetcher.fetch_object(object_uri) do
      {:ok, object} when is_map(object) ->
        handle(%{"object" => object}, actor_uri, target_user)

      {:error, reason} ->
        Logger.warning("Failed to fetch Update object #{object_uri}: #{inspect(reason)}")
        {:ok, :fetch_failed}
    end
  end

  def handle(_activity, _actor_uri, _target_user) do
    {:ok, :unhandled}
  end

  defp update_note(object, actor_uri) do
    case Messaging.get_message_by_activitypub_id(object["id"]) do
      nil ->
        {:ok, :unknown_object}

      message ->
        remote_actor = ActivityPub.get_actor_by_uri(actor_uri)

        if remote_actor && message.remote_actor_id == remote_actor.id do
          content = strip_html(object["content"] || "")

          Messaging.update_message(message, %{
            content: content,
            edited_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

          {:ok, :updated}
        else
          {:error, :unauthorized}
        end
    end
  end

  defp strip_html(html) do
    html
    |> String.replace(~r/<br\s*\/?>/, "\n")
    |> String.replace(~r/<p[^>]*>/, "\n")
    |> String.replace(~r/<\/p>/, "\n")
    |> String.replace(~r/<[^>]*>/, "")
    |> HtmlEntities.decode()
    |> String.trim()
  end
end
