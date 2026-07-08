defmodule ElektrineSocialWeb.RemoteUserLive.TimelineLoader do
  @moduledoc """
  Timeline loading for the remote user profile LiveView.

  Handles the `handle_info` flows that load and refresh locally cached posts,
  reply previews, and per-post counts. Every `handle_info` entry point takes
  the socket and returns a `{:noreply, socket}` tuple.
  """

  import Phoenix.Component
  import ElektrineWeb.Live.Helpers.PostStateHelpers, only: [get_post_reactions: 1]

  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Messages, as: MessagingMessages
  alias ElektrineSocialWeb.Components.Social.PostUtilities
  alias ElektrineSocialWeb.RemoteUserLive.PostState
  alias ElektrineSocialWeb.RemoteUserLive.ReactionSurfaces

  @reply_preview_poll_interval_ms 1_500
  @reply_preview_poll_max_attempts 8

  def load_timeline(socket) do
    remote_actor = socket.assigns.remote_actor

    # Check for nil actor (can happen if fetch failed)
    if is_nil(remote_actor) do
      {:noreply, assign(socket, :loading, false)}
    else
      is_lemmy = remote_actor.actor_type == "Group"

      # Use already-loaded local posts if available, otherwise load them now
      local_posts =
        if socket.assigns.local_posts && socket.assigns.local_posts != [] do
          socket.assigns.local_posts
        else
          get_local_posts_from_remote_actor(remote_actor)
        end

      # Load interaction state for local posts if not already loaded
      post_interactions =
        if socket.assigns[:current_user] && local_posts != [] &&
             map_size(socket.assigns.post_interactions) == 0 do
          PostState.load_post_interactions(local_posts, socket.assigns.current_user.id)
        else
          socket.assigns.post_interactions
        end

      user_saves =
        if socket.assigns[:current_user] && local_posts != [] &&
             map_size(socket.assigns.user_saves) == 0 do
          PostState.load_user_saves_for_posts(local_posts, socket.assigns.current_user.id)
        else
          socket.assigns.user_saves
        end

      post_reactions =
        ReactionSurfaces.normalize_post_reaction_keys(get_post_reactions(local_posts))

      # Show local posts immediately
      socket =
        socket
        |> assign(:local_posts, local_posts)
        |> assign(:post_interactions, post_interactions)
        |> assign(:user_saves, user_saves)
        |> assign(:post_reactions, post_reactions)
        |> assign(:loading, false)

      # PHASE 2: Kick off remote fetches in background (non-blocking)
      pid = self()

      # Load replies/comments for posts we already have cached.
      schedule_replies_fetch(local_posts, pid)

      # Sync remote outbox via Oban and reload local posts after it runs.
      _ = ElektrineSocial.RemoteUser.OutboxSyncWorker.enqueue(remote_actor.id, limit: 20)
      Process.send_after(self(), :reload_remote_profile_posts, 1_500)

      # Fetch Lemmy counts in background
      if is_lemmy && local_posts != [] do
        _ = ElektrineSocial.RemoteUser.MetricsWorker.enqueue(remote_actor.id, "counts")
        Process.send_after(self(), :reload_remote_user_counts, 1_500)
      end

      {:noreply, socket}
    end
  end

  def reload_remote_profile_posts(socket) do
    remote_actor = socket.assigns.remote_actor

    if remote_actor do
      local_posts = get_local_posts_from_remote_actor(remote_actor)

      post_interactions =
        if socket.assigns[:current_user] && local_posts != [] do
          PostState.load_post_interactions(local_posts, socket.assigns.current_user.id)
        else
          socket.assigns.post_interactions
        end

      user_saves =
        if socket.assigns[:current_user] && local_posts != [] do
          PostState.load_user_saves_for_posts(local_posts, socket.assigns.current_user.id)
        else
          socket.assigns.user_saves
        end

      post_reactions =
        ReactionSurfaces.normalize_post_reaction_keys(get_post_reactions(local_posts))

      schedule_replies_fetch(local_posts, self())

      {:noreply,
       socket
       |> assign(:local_posts, local_posts)
       |> assign(:post_interactions, post_interactions)
       |> assign(:user_saves, user_saves)
       |> assign(:post_reactions, post_reactions)}
    else
      {:noreply, socket}
    end
  end

  def reload_local_posts_after_poll_refresh(socket) do
    remote_actor = socket.assigns.remote_actor

    if remote_actor do
      local_posts = get_local_posts_from_remote_actor(remote_actor)

      post_reactions =
        ReactionSurfaces.normalize_post_reaction_keys(get_post_reactions(local_posts))

      {:noreply,
       socket
       |> assign(:local_posts, local_posts)
       |> assign(:post_reactions, post_reactions)
       |> assign(:poll_refresh_nonce, System.unique_integer([:positive, :monotonic]))}
    else
      {:noreply, socket}
    end
  end

  def replies_loaded_for_posts(socket, post_replies) do
    current_replies = socket.assigns.post_replies || %{}
    {:noreply, assign(socket, :post_replies, Map.merge(current_replies, post_replies))}
  end

  def refresh_post_replies(socket, post_refs, attempt) do
    post_replies = load_local_replies_for_post_refs(post_refs)

    cond do
      map_size(post_replies) > 0 ->
        current_replies = socket.assigns.post_replies || %{}
        {:noreply, assign(socket, :post_replies, Map.merge(current_replies, post_replies))}

      attempt < @reply_preview_poll_max_attempts ->
        Process.send_after(
          self(),
          {:refresh_post_replies, post_refs, attempt + 1},
          @reply_preview_poll_interval_ms
        )

        {:noreply, socket}

      true ->
        {:noreply, socket}
    end
  end

  def post_counts_updated(socket, message_id, counts) do
    updated_local_posts =
      Enum.map(socket.assigns.local_posts || [], fn post ->
        if post.id == message_id do
          %{
            post
            | like_count: counts.like_count,
              share_count: counts.share_count,
              reply_count: counts.reply_count
          }
        else
          post
        end
      end)

    updated_modal_post =
      case socket.assigns[:modal_post] do
        %{id: ^message_id} = post ->
          %{
            post
            | like_count: counts.like_count,
              share_count: counts.share_count,
              reply_count: counts.reply_count
          }

        post ->
          post
      end

    updated_lemmy_counts =
      case Enum.find(updated_local_posts, &(&1.id == message_id)) do
        %{activitypub_id: activitypub_id} when is_binary(activitypub_id) ->
          existing = Map.get(socket.assigns.lemmy_counts || %{}, activitypub_id, %{})

          Map.put(
            socket.assigns.lemmy_counts || %{},
            activitypub_id,
            existing
            |> Map.put(:score, counts.like_count)
            |> Map.put(:comments, counts.reply_count)
          )

        _ ->
          socket.assigns.lemmy_counts || %{}
      end

    updated_mastodon_counts =
      case Enum.find(updated_local_posts, &(&1.id == message_id)) do
        %{activitypub_id: activitypub_id} when is_binary(activitypub_id) ->
          existing = Map.get(socket.assigns.mastodon_counts || %{}, activitypub_id, %{})

          Map.put(
            socket.assigns.mastodon_counts || %{},
            activitypub_id,
            existing
            |> Map.put(:favourites_count, counts.like_count)
            |> Map.put(:reblogs_count, counts.share_count)
            |> Map.put(:replies_count, counts.reply_count)
          )

        _ ->
          socket.assigns.mastodon_counts || %{}
      end

    {:noreply,
     socket
     |> assign(:local_posts, updated_local_posts)
     |> assign(:modal_post, updated_modal_post)
     |> assign(:lemmy_counts, updated_lemmy_counts)
     |> assign(:mastodon_counts, updated_mastodon_counts)}
  end

  def schedule_replies_fetch(posts, liveview_pid) when is_list(posts) do
    candidates =
      posts
      |> Enum.filter(&reply_fetch_candidate?/1)
      |> Enum.take(10)

    if candidates != [] do
      refs = reply_preview_refs(candidates)
      post_replies = load_local_replies_for_post_refs(refs)

      if map_size(post_replies) > 0 do
        send(liveview_pid, {:replies_loaded_for_posts, post_replies})
      end

      candidates
      |> Enum.map(&message_id_for_reply_fetch/1)
      |> Enum.filter(&is_integer/1)
      |> Enum.each(fn message_id ->
        _ = Elektrine.ActivityPub.RepliesIngestWorker.enqueue(message_id)
      end)

      refs = reply_preview_refs(candidates)

      if refs != [] do
        Process.send_after(self(), {:refresh_post_replies, refs, 1}, 0)
      end
    end
  end

  def schedule_replies_fetch(_, _), do: :ok

  defp reply_fetch_candidate?(%{"id" => id} = post) when is_binary(id) do
    has_collection_ref?(post["replies"]) ||
      has_collection_ref?(post["comments"]) ||
      parse_non_negative_count(post["repliesCount"]) > 0 ||
      extract_count_from_collection(post["replies"]) > 0 ||
      extract_count_from_collection(post["comments"]) > 0
  end

  defp reply_fetch_candidate?(%{activitypub_id: id} = post) when is_binary(id) do
    metadata = post.media_metadata || %{}

    cached_reply_count(post) > 0 ||
      has_collection_ref?(metadata["replies"]) ||
      has_collection_ref?(metadata["comments"])
  end

  defp reply_fetch_candidate?(_), do: false

  defp load_local_replies_for_post_refs(post_refs) when is_list(post_refs) do
    post_refs
    |> Enum.reduce(%{}, fn ref, acc ->
      case fetch_replies_for_post(ref) do
        {post_id, replies} when is_binary(post_id) and is_list(replies) and replies != [] ->
          Map.put(acc, post_id, replies)

        _ ->
          acc
      end
    end)
  end

  defp load_local_replies_for_post_refs(_), do: %{}

  defp fetch_replies_for_post(%{message_id: message_id, post_id: post_id})
       when is_integer(message_id) and is_binary(post_id) do
    replies =
      Social.get_direct_replies_for_posts([message_id], limit_per_post: 20)
      |> Map.get(message_id, [])
      |> Enum.map(&local_reply_to_preview/1)

    {post_id, replies}
  end

  defp fetch_replies_for_post(%{activitypub_id: post_id} = post) when is_binary(post_id) do
    case message_id_for_reply_fetch(post) do
      message_id when is_integer(message_id) ->
        fetch_replies_for_post(%{message_id: message_id, post_id: post_id})

      _ ->
        {post_id, []}
    end
  end

  defp fetch_replies_for_post(%{"id" => post_id}) when is_binary(post_id) do
    case Elektrine.Messaging.get_message_by_activitypub_ref(post_id) do
      %{id: message_id} -> fetch_replies_for_post(%{message_id: message_id, post_id: post_id})
      _ -> {post_id, []}
    end
  end

  defp fetch_replies_for_post(_), do: {nil, []}

  defp reply_preview_refs(posts) when is_list(posts) do
    posts
    |> Enum.map(fn post ->
      case post do
        %{id: message_id, activitypub_id: post_id}
        when is_integer(message_id) and is_binary(post_id) ->
          %{message_id: message_id, post_id: post_id}

        %{"id" => post_id} when is_binary(post_id) ->
          case Elektrine.Messaging.get_message_by_activitypub_ref(post_id) do
            %{id: message_id} -> %{message_id: message_id, post_id: post_id}
            _ -> nil
          end

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp reply_preview_refs(_), do: []

  defp message_id_for_reply_fetch(%{id: id}) when is_integer(id), do: id

  defp message_id_for_reply_fetch(%{"id" => post_id}) when is_binary(post_id) do
    case Elektrine.Messaging.get_message_by_activitypub_ref(post_id) do
      %{id: message_id} -> message_id
      _ -> nil
    end
  end

  defp message_id_for_reply_fetch(_), do: nil

  defp local_reply_to_preview(reply) do
    base_url = ElektrineWeb.Endpoint.url()

    {actor_uri, local_user} =
      cond do
        reply.sender && Elektrine.Strings.present?(reply.sender.username) ->
          {"#{base_url}/users/#{reply.sender.username}", reply.sender}

        reply.remote_actor && Elektrine.Strings.present?(reply.remote_actor.uri) ->
          {reply.remote_actor.uri, nil}

        reply.remote_actor && Elektrine.Strings.present?(reply.remote_actor.domain) &&
            Elektrine.Strings.present?(reply.remote_actor.username) ->
          {"https://#{reply.remote_actor.domain}/users/#{reply.remote_actor.username}", nil}

        true ->
          {nil, nil}
      end

    %{
      "id" => reply.activitypub_id || "#{base_url}/posts/#{reply.id}",
      "type" => "Note",
      "content" => reply.content,
      "published" => NaiveDateTime.to_iso8601(reply.inserted_at) <> "Z",
      "attributedTo" => actor_uri,
      "_local_user" => local_user,
      "_local_message_id" => reply.id
    }
  end

  defp has_collection_ref?(value) when is_binary(value), do: true

  defp has_collection_ref?(value) when is_map(value) do
    is_binary(value["id"]) || is_binary(value["first"]) || is_list(value["items"]) ||
      is_list(value["orderedItems"]) ||
      parse_non_negative_count(value["totalItems"]) > 0
  end

  defp has_collection_ref?(_), do: false

  defp cached_reply_count(post) do
    metadata = post.media_metadata || %{}

    [
      parse_non_negative_count(post.reply_count),
      parse_non_negative_count(metadata["original_reply_count"]),
      parse_non_negative_count(metadata["reply_count"]),
      parse_non_negative_count(metadata["replies_count"]),
      extract_count_from_collection(metadata["replies"]),
      extract_count_from_collection(metadata["comments"])
    ]
    |> Enum.max(fn -> 0 end)
  end

  def get_local_posts_from_remote_actor(remote_actor) do
    import Ecto.Query
    preloads = MessagingMessages.timeline_post_preloads()

    # For Group actors (Lemmy communities), query by community_actor_uri in media_metadata
    # These posts may not have a conversation_id (federated community posts)
    # For Person actors, query by remote_actor_id
    if remote_actor.actor_type == "Group" do
      # For Lemmy communities: posts are "Page" type, comments are "Note" type
      # Filter to only show Page type (or null for legacy posts without type stored)
      # Also filter out Lemmy comment URLs which contain "/comment/"
      Repo.all(
        from(m in Elektrine.Social.Message,
          left_join: c in Elektrine.Social.Conversation,
          on: c.id == m.conversation_id,
          where: fragment("?->>'community_actor_uri' = ?", m.media_metadata, ^remote_actor.uri),
          where: is_nil(c.id) or c.type in ["timeline", "community"],
          where: m.visibility == "public" or is_nil(m.visibility),
          where: is_nil(m.deleted_at),
          where: is_nil(m.reply_to_id),
          # Filter out comments: must not have inReplyTo
          where:
            fragment("?->>'inReplyTo' IS NULL OR ? IS NULL", m.media_metadata, m.media_metadata),
          # For Lemmy: must be Page/Article type (not Note), OR no type stored but not a comment URL
          where:
            fragment(
              "(?->>'type' = 'Page' OR ?->>'type' = 'Article') OR (?->>'type' IS NULL AND ? NOT LIKE '%/comment/%')",
              m.media_metadata,
              m.media_metadata,
              m.media_metadata,
              m.activitypub_id
            ),
          order_by: [desc: m.inserted_at],
          limit: 50,
          preload: ^preloads
        )
      )
      |> PostUtilities.attach_cached_link_previews()
    else
      # For Person actors, query by remote_actor_id
      # Use left_join since federated posts might not have a conversation
      # Include replies - they'll be displayed with a "replying to" indicator
      Repo.all(
        from(m in Elektrine.Social.Message,
          left_join: c in Elektrine.Social.Conversation,
          on: c.id == m.conversation_id,
          where: m.remote_actor_id == ^remote_actor.id,
          where: is_nil(c.id) or c.type == "timeline",
          where: m.visibility == "public" or is_nil(m.visibility),
          where: is_nil(m.deleted_at),
          order_by: [desc: m.inserted_at],
          limit: 50,
          preload: ^preloads
        )
      )
      |> PostUtilities.attach_cached_link_previews()
    end
  end

  defp extract_count_from_collection(nil), do: 0

  defp extract_count_from_collection(collection) when is_map(collection) do
    parse_non_negative_count(collection["totalItems"])
  end

  defp extract_count_from_collection(collection) when is_integer(collection), do: collection

  defp extract_count_from_collection(collection) when is_binary(collection),
    do: parse_non_negative_count(collection)

  defp extract_count_from_collection(_), do: 0

  defp parse_non_negative_count(value) when is_integer(value), do: max(value, 0)

  defp parse_non_negative_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> max(parsed, 0)
      :error -> 0
    end
  end

  defp parse_non_negative_count(_), do: 0
end
