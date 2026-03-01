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
  # Trigger an initial sync shortly after boot so new follows populate promptly.
  @initial_fetch_delay_ms 15_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :fetch_community_posts, @initial_fetch_delay_ms)
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

    # Include communities from accepted follows and federated mirrors with active members.
    # This keeps ingestion flowing even if remote instances delay or skip Follow Accept.
    from(a in Actor,
      left_join: f in Elektrine.Profiles.Follow,
      on: f.remote_actor_id == a.id and not is_nil(f.follower_id),
      left_join: c in Elektrine.Messaging.Conversation,
      on:
        c.remote_group_actor_id == a.id and c.is_federated_mirror == true and
          c.type == "community",
      left_join: cm in Elektrine.Messaging.ConversationMember,
      on: cm.conversation_id == c.id and is_nil(cm.left_at),
      where: a.actor_type == "Group" and (not is_nil(f.id) or not is_nil(cm.id)),
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
