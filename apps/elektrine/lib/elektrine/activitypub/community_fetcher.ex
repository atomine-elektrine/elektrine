defmodule Elektrine.ActivityPub.CommunityFetcher do
  @moduledoc false

  require Logger

  alias Elektrine.Social.Message

  def handle_info(:fetch_community_posts, state) when is_map(state) do
    config = Application.get_env(:elektrine, :community_fetcher, [])
    followed_communities = Keyword.get(config, :followed_communities, fn -> [] end)
    activitypub = Keyword.get(config, :activitypub, Elektrine.ActivityPub)
    handler = Keyword.get(config, :handler, Elektrine.ActivityPub.Handler)
    messaging = Keyword.get(config, :messaging, Elektrine.Messaging)
    sleep = Keyword.get(config, :sleep, fn _ -> :ok end)

    followed_communities.()
    |> Enum.each(fn community_actor ->
      fetch_and_store_posts(activitypub, handler, messaging, sleep, community_actor)
    end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp fetch_and_store_posts(activitypub, handler, messaging, sleep, community_actor) do
    case activitypub.fetch_remote_user_timeline(community_actor.uri, []) do
      {:ok, posts} when is_list(posts) ->
        Enum.each(posts, fn post_object ->
          process_post(handler, messaging, community_actor, post_object)
          sleep.(:between_posts)
        end)

      _ ->
        :ok
    end
  end

  defp process_post(handler, messaging, community_actor, post_object) when is_map(post_object) do
    actor_uri = post_object["attributedTo"] || community_actor.uri

    try do
      case handler.store_remote_post(post_object, actor_uri) do
        {:ok, %Message{} = message} ->
          metadata =
            Map.merge(message.media_metadata || %{}, %{
              "community_actor_uri" => community_actor.uri
            })

          _ = messaging.update_message(message, %{media_metadata: metadata})
          :ok

        _ ->
          :ok
      end
    rescue
      error ->
        post_id = Map.get(post_object, "id")

        Logger.warning(
          "Community fetch ingest failed for #{inspect(post_id)}: #{Exception.message(error)}"
        )

        :ok
    end
  end

  defp process_post(_handler, _messaging, _community_actor, _post_object), do: :ok
end
