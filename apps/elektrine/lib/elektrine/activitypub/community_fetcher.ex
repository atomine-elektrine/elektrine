defmodule Elektrine.ActivityPub.CommunityFetcher do
  @moduledoc """
  Background worker to fetch posts from followed remote communities.
  Runs periodically to sync community posts into the local timeline.
  """

  use GenServer
  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Actor, Handler}
  alias Elektrine.Repo

  # Fetch interval: 30 minutes (increased from 10 to reduce resource usage)
  @fetch_interval_ms 30 * 60 * 1000
  # Max communities to fetch per cycle (to avoid overwhelming HTTP pool)
  @max_communities_per_cycle 3
  # Delay between community fetches (5 seconds)
  @delay_between_fetches 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :fetch_community_posts, 120_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:fetch_community_posts, state) do
    # Get all followed Group actors
    followed_communities = get_followed_communities()

    # Only process a limited number per cycle to avoid pool exhaustion
    communities_to_fetch = Enum.take(followed_communities, @max_communities_per_cycle)

    # Fetch posts from each community with delay between fetches
    Enum.each(communities_to_fetch, fn community_actor ->
      fetch_and_store_community_posts(community_actor)
      # Add delay between communities to avoid HTTP pool exhaustion
      Process.sleep(@delay_between_fetches)
    end)

    # Schedule next fetch
    Process.send_after(self(), :fetch_community_posts, @fetch_interval_ms)
    {:noreply, state}
  end

  defp get_followed_communities do
    import Ecto.Query

    # Get all remote Group actors that are being followed by local users
    from(f in Elektrine.Profiles.Follow,
      join: a in Actor,
      on: f.remote_actor_id == a.id,
      where: a.actor_type == "Group" and f.pending == false,
      distinct: a.id,
      select: a
    )
    |> Repo.all()
  end

  defp fetch_and_store_community_posts(community_actor) do
    # Use the same timeline fetching we use for remote users
    # This works for both Person and Group actors
    case ActivityPub.fetch_remote_user_timeline(community_actor.id, limit: 20) do
      {:ok, posts} ->
        # Store each post if we don't have it
        Enum.each(posts, fn post_object ->
          post_id = post_object["id"]

          unless post_already_exists?(post_id) do
            # Store using the handler (same as remote user posts)
            case Handler.store_remote_post(post_object, community_actor.uri) do
              {:ok, message} ->
                # Mark it as from the followed community.
                # Do not copy raw "audience" values because many posts use Public there.
                Elektrine.Messaging.update_message(message, %{
                  media_metadata:
                    Map.merge(message.media_metadata || %{}, %{
                      "community_actor_uri" => community_actor.uri
                    })
                })

              {:error, _reason} ->
                :ok
            end
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "Failed to fetch community timeline for #{community_actor.username}@#{community_actor.domain}: #{inspect(reason)}"
        )
    end
  end

  defp post_already_exists?(activitypub_id) do
    Elektrine.Messaging.get_message_by_activitypub_id(activitypub_id) != nil
  end
end
