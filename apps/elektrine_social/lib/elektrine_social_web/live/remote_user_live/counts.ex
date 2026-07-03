defmodule ElektrineSocialWeb.RemoteUserLive.Counts do
  @moduledoc """
  Community stats, Lemmy/Mastodon counts, and remote relationship counts for
  the remote user profile LiveView.

  Each `handle_info` entry point takes the socket and returns a
  `{:noreply, socket}` tuple.
  """

  import Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1]

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.CollectionFetcher
  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.Repo

  @community_stats_poll_interval_ms 1_500
  @community_stats_poll_max_attempts 8

  def load_community_stats(socket) do
    case socket.assigns.remote_actor do
      %{actor_type: "Group"} = remote_actor ->
        _ = ElektrineSocial.RemoteUser.MetricsWorker.enqueue(remote_actor.id, "community_stats")

        Process.send_after(
          self(),
          {:reload_remote_user_community_stats, remote_actor.id, 1},
          @community_stats_poll_interval_ms
        )

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def community_stats_loaded(socket, stats) do
    {:noreply,
     assign(
       socket,
       :community_stats,
       merge_community_stats(socket.assigns[:community_stats] || %{members: 0, posts: 0}, stats)
     )}
  end

  def load_remote_relationship_counts(socket, actor_id) do
    current_actor = socket.assigns[:remote_actor]

    if current_actor && current_actor.id == actor_id do
      live_view = self()

      Task.start(fn ->
        counts = fetch_remote_relationship_counts(actor_id)
        send(live_view, {:remote_relationship_counts_loaded, actor_id, counts})
      end)
    end

    {:noreply, socket}
  end

  def remote_relationship_counts_loaded(socket, actor_id, counts) do
    current_actor = socket.assigns[:remote_actor]

    if current_actor && current_actor.id == actor_id && is_map(counts) do
      updated_metadata = merge_remote_relationship_counts(current_actor.metadata || %{}, counts)
      updated_actor = %{current_actor | metadata: updated_metadata}

      {:noreply,
       socket
       |> assign(:remote_actor, updated_actor)
       |> assign(
         :community_stats,
         resolved_community_stats(updated_actor, socket.assigns[:community_stats])
       )}
    else
      {:noreply, socket}
    end
  end

  def refresh_remote_counts(socket) do
    if socket.assigns.remote_actor && (socket.assigns.local_posts || []) != [] do
      _ =
        ElektrineSocial.RemoteUser.MetricsWorker.enqueue(socket.assigns.remote_actor.id, "counts")

      Process.send_after(self(), :reload_remote_user_counts, 1_500)
      Process.send_after(self(), :refresh_remote_counts, 60_000)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def reload_remote_user_counts(socket) do
    remote_actor = socket.assigns.remote_actor

    if remote_actor do
      cached = ElektrineSocial.RemoteUser.Metrics.cached_counts(remote_actor.id)

      {:noreply,
       socket
       |> assign(:lemmy_counts, cached.lemmy_counts || %{})
       |> assign(:mastodon_counts, cached.mastodon_counts || %{})}
    else
      {:noreply, socket}
    end
  end

  def reload_remote_user_community_stats(socket, actor_id, attempt) do
    current_actor = socket.assigns[:remote_actor]

    if current_actor && current_actor.id == actor_id do
      stats = ElektrineSocial.RemoteUser.Metrics.cached_community_stats(actor_id)

      if community_stats_ready?(stats) || attempt >= @community_stats_poll_max_attempts do
        send(self(), {:community_stats_loaded, stats})
        {:noreply, socket}
      else
        Process.send_after(
          self(),
          {:reload_remote_user_community_stats, actor_id, attempt + 1},
          @community_stats_poll_interval_ms
        )

        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  defp initial_community_stats(%{actor_type: "Group", metadata: metadata}) do
    metadata = metadata || %{}

    %{
      members: APHelpers.get_follower_count(metadata),
      posts: APHelpers.get_status_count(metadata)
    }
  end

  defp initial_community_stats(_), do: %{members: 0, posts: 0}

  def resolved_community_stats(%{actor_type: "Group", id: actor_id} = actor, current_stats)
      when is_integer(actor_id) do
    merge_community_stats(
      merge_community_stats(current_stats, initial_community_stats(actor)),
      ElektrineSocial.RemoteUser.Metrics.cached_community_stats(actor_id)
    )
  end

  def resolved_community_stats(actor, current_stats) do
    merge_community_stats(current_stats, initial_community_stats(actor))
  end

  defp merge_community_stats(current_stats, incoming_stats) do
    %{
      members: merged_community_stat(current_stats, incoming_stats, :members),
      posts: merged_community_stat(current_stats, incoming_stats, :posts)
    }
  end

  defp merged_community_stat(current_stats, incoming_stats, key) do
    if community_stat_present?(incoming_stats, key) do
      incoming_stats
      |> Map.get(key, Map.get(incoming_stats, Atom.to_string(key)))
      |> normalize_community_stat_value()
    else
      current_stats
      |> Map.get(key, Map.get(current_stats, Atom.to_string(key)))
      |> normalize_community_stat_value()
    end
  end

  defp community_stat_present?(stats, key) when is_map(stats) do
    Map.has_key?(stats, key) or Map.has_key?(stats, Atom.to_string(key))
  end

  defp community_stat_present?(_, _), do: false

  defp normalize_community_stat_value(value) when is_integer(value), do: max(value, 0)

  defp normalize_community_stat_value(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> max(parsed, 0)
      :error -> 0
    end
  end

  defp normalize_community_stat_value(_), do: 0

  defp community_stats_ready?(%{} = stats) do
    (stats[:members] || 0) > 0 || (stats[:posts] || 0) > 0
  end

  def maybe_schedule_remote_relationship_counts(socket, remote_actor) do
    if connected?(socket) && remote_relationship_counts_stale?(remote_actor) do
      send(self(), {:load_remote_relationship_counts, remote_actor.id})
    end

    socket
  end

  defp remote_relationship_counts_stale?(
         %{followers_url: followers_url, following_url: following_url} = actor
       ) do
    has_collection_url? =
      Elektrine.Strings.present?(followers_url) || Elektrine.Strings.present?(following_url)

    has_collection_url? && relationship_counts_stale_at?(actor.metadata || %{})
  end

  defp remote_relationship_counts_stale?(_), do: false

  defp relationship_counts_stale_at?(metadata) when is_map(metadata) do
    case metadata["relationship_counts_fetched_at"] do
      fetched_at when is_binary(fetched_at) ->
        case DateTime.from_iso8601(fetched_at) do
          {:ok, datetime, _offset} -> DateTime.diff(DateTime.utc_now(), datetime, :hour) >= 6
          _ -> true
        end

      _ ->
        true
    end
  end

  defp relationship_counts_stale_at?(_), do: true

  defp fetch_remote_relationship_counts(actor_id) do
    case ActivityPub.get_remote_actor(actor_id) do
      %{id: ^actor_id} = actor ->
        counts = %{
          "followers_count" =>
            fetch_remote_collection_count(
              actor.followers_url || get_in(actor.metadata || %{}, ["followers"]),
              APHelpers.get_follower_count(actor.metadata || %{})
            ),
          "following_count" =>
            fetch_remote_collection_count(
              actor.following_url || get_in(actor.metadata || %{}, ["following"]),
              APHelpers.get_following_count(actor.metadata || %{})
            )
        }

        metadata = merge_remote_relationship_counts(actor.metadata || %{}, counts)

        actor
        |> Elektrine.ActivityPub.Actor.changeset(%{metadata: metadata})
        |> Repo.update()
        |> case do
          {:ok, updated_actor} -> Map.take(updated_actor.metadata || %{}, Map.keys(counts))
          {:error, _changeset} -> counts
        end

      _ ->
        %{}
    end
  rescue
    error in Postgrex.Error ->
      Logger.warning(
        "Skipping remote relationship count refresh for actor #{inspect(actor_id)} after database error: #{Exception.message(error)}"
      )

      %{}
  end

  defp fetch_remote_collection_count(nil, fallback), do: max(fallback || 0, 0)

  defp fetch_remote_collection_count(source, fallback) do
    case CollectionFetcher.fetch_collection_count(source) do
      {:ok, count} when is_integer(count) -> max(count, 0)
      {:error, _reason} -> max(fallback || 0, 0)
    end
  end

  defp merge_remote_relationship_counts(metadata, counts)
       when is_map(metadata) and is_map(counts) do
    counts
    |> Enum.reduce(metadata, fn {key, value}, acc ->
      Map.put(acc, to_string(key), normalize_community_stat_value(value))
    end)
    |> Map.put(
      "relationship_counts_fetched_at",
      DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    )
  end
end
