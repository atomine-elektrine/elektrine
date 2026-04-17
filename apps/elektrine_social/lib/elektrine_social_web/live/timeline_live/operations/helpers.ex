defmodule ElektrineSocialWeb.TimelineLive.Operations.Helpers do
  @moduledoc """
  Shared helper functions for timeline operation modules.
  """

  import Phoenix.Component
  import Phoenix.LiveView
  alias Elektrine.ActivityPub.LemmyApi
  alias Elektrine.ActivityPub.LemmyCache
  alias Elektrine.Messaging.Messages, as: MessagingMessages
  alias ElektrineSocialWeb.Components.Social.PostUtilities

  def load_cached_lemmy_counts(posts, timeline_view)

  def load_cached_lemmy_counts(posts, "communities") when is_list(posts) do
    activitypub_ids =
      posts
      |> Enum.map(&Map.get(&1, :activitypub_id))
      |> Enum.filter(&LemmyApi.community_post_url?/1)

    if activitypub_ids == [] do
      %{}
    else
      counts = LemmyCache.get_cached_counts(activitypub_ids)
      _ = LemmyCache.schedule_refresh(activitypub_ids)
      counts
    end
  end

  def load_cached_lemmy_counts(_posts, _timeline_view), do: %{}

  # Apply timeline filter to socket
  def apply_timeline_filter(socket) do
    filtered_posts =
      case socket.assigns.timeline_filter do
        "posts" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            is_nil(Map.get(post, :reply_to_id)) &&
              !PostUtilities.community_post?(post)
          end)

        "replies" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            !is_nil(Map.get(post, :reply_to_id)) ||
              !is_nil(get_in(post.media_metadata, ["inReplyTo"]))
          end)

        "media" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            media_urls = Map.get(post, :media_urls, [])
            has_media_urls = !Enum.empty?(media_urls)
            link_preview = Map.get(post, :link_preview)

            has_link_preview =
              match?(%Elektrine.Social.LinkPreview{}, link_preview) &&
                link_preview.status == "success" &&
                link_preview.image_url != nil

            has_media_urls || has_link_preview
          end)

        "friends" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            post.sender_id && post.sender_id in socket.assigns.friend_ids
          end)

        "my_posts" ->
          if socket.assigns.current_user do
            Enum.filter(socket.assigns.timeline_posts, fn post ->
              post.sender_id == socket.assigns.current_user.id
            end)
          else
            []
          end

        "trusted" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            post.federated != true &&
              (post.sender || %{}) |> Map.get(:trust_level, 0) >= 2
          end)

        "communities" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            PostUtilities.community_post?(post)
          end)

        "federated" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            post.federated == true
          end)

        "local" ->
          # Local posts have a sender_id (local user) and no remote_actor_id
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            !is_nil(post.sender_id) && is_nil(post.remote_actor_id)
          end)

        _ ->
          socket.assigns.timeline_posts
      end
      |> dedupe_posts()

    filtered_posts = filter_posts_by_software(filtered_posts, socket.assigns.software_filter)
    filtered_posts = filter_posts_by_search_query(filtered_posts, socket.assigns[:search_query])
    filtered_posts = maybe_prioritize_non_community_posts(filtered_posts, socket)
    filtered_posts = dedupe_posts(filtered_posts)
    assign_filtered_posts(socket, filtered_posts)
  end

  def assign_filtered_posts(socket, filtered_posts) when is_list(filtered_posts) do
    previous_posts = socket.assigns[:filtered_posts] || []
    previous_ids = socket.assigns[:filtered_post_ids] || []
    previous_posts_by_id = Map.new(previous_posts, fn post -> {post.id, post} end)
    current_ids = Enum.map(filtered_posts, & &1.id)

    changed_posts =
      Enum.filter(filtered_posts, fn post ->
        Map.get(previous_posts_by_id, post.id) != post
      end)

    changed_existing_posts =
      Enum.filter(changed_posts, fn post ->
        Map.has_key?(previous_posts_by_id, post.id)
      end)

    socket =
      socket
      |> assign(:filtered_posts, filtered_posts)
      |> assign(:filtered_post_ids, current_ids)

    cond do
      previous_ids == current_ids ->
        refresh_changed_filtered_posts(socket, changed_posts)

      ids_prefixed?(previous_ids, current_ids) ->
        appended_posts = Enum.drop(filtered_posts, length(previous_ids))

        socket
        |> append_filtered_posts(appended_posts)
        |> refresh_changed_filtered_posts(changed_existing_posts)

      ids_suffixed?(previous_ids, current_ids) ->
        prepended_count = length(current_ids) - length(previous_ids)
        prepended_posts = Enum.take(filtered_posts, prepended_count)

        socket
        |> prepend_filtered_posts(prepended_posts)
        |> refresh_changed_filtered_posts(changed_existing_posts)

      ids_subsequence?(current_ids, previous_ids) ->
        removed_ids = previous_ids -- current_ids

        socket
        |> remove_filtered_posts(previous_posts_by_id, removed_ids)
        |> refresh_changed_filtered_posts(changed_existing_posts)

      true ->
        stream(socket, :timeline_filtered_posts, filtered_posts, reset: true)
    end
  end

  def assign_filtered_posts(socket, _), do: assign_filtered_posts(socket, [])

  def refresh_filtered_posts_stream(socket) do
    stream(socket, :timeline_filtered_posts, socket.assigns[:filtered_posts] || [], reset: true)
  end

  def refresh_filtered_posts(socket, post_ids) when is_list(post_ids) do
    touch_filtered_posts(socket, post_ids)
  end

  def refresh_filtered_posts(socket, _), do: socket

  def refresh_interaction_posts(socket, message_id) do
    case interaction_refresh_post_ids(socket, message_id) do
      [] -> socket
      post_ids -> touch_filtered_posts(socket, post_ids)
    end
  end

  def touch_filtered_posts(socket, post_ids) when is_list(post_ids) do
    normalized_ids =
      post_ids
      |> Enum.map(&normalize_post_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    posts =
      socket.assigns[:filtered_posts]
      |> Kernel.||([])
      |> Enum.filter(fn post -> MapSet.member?(normalized_ids, normalize_post_id(post.id)) end)

    refresh_changed_filtered_posts(socket, posts)
  end

  def touch_filtered_posts(socket, post_id), do: touch_filtered_posts(socket, [post_id])

  def touch_interaction_posts(socket, message_id) do
    case interaction_refresh_post_ids(socket, message_id) do
      [] -> socket
      post_ids -> touch_filtered_posts(socket, post_ids)
    end
  end

  def refresh_filtered_post(socket, post_id) do
    touch_filtered_posts(socket, post_id)
  end

  def refresh_posts_for_remote_actor(socket, remote_actor_id) do
    post_ids =
      socket.assigns[:filtered_posts]
      |> Kernel.||([])
      |> Enum.filter(&(&1.remote_actor_id == remote_actor_id))
      |> Enum.map(& &1.id)

    refresh_filtered_posts(socket, post_ids)
  end

  def push_remote_follow_state(socket, remote_actor_id, state)

  def push_remote_follow_state(socket, remote_actor_id, state)
      when state in [:following, :pending, :none] do
    push_remote_follow_state(socket, remote_actor_id, Atom.to_string(state))
  end

  def push_remote_follow_state(socket, remote_actor_id, state) when is_binary(state) do
    push_event(socket, "remote_follow_state_changed", %{
      remote_actor_id: remote_actor_id,
      state: state
    })
  end

  def put_remote_follow_override(socket, remote_actor_id, state)
      when state in [:following, :pending, :none] do
    update(socket, :remote_follow_overrides, fn overrides ->
      Map.put(overrides || %{}, remote_actor_id, Atom.to_string(state))
    end)
  end

  def refresh_posts_for_sender(socket, sender_id) do
    post_ids =
      socket.assigns[:filtered_posts]
      |> Kernel.||([])
      |> Enum.filter(&(&1.sender_id == sender_id))
      |> Enum.map(& &1.id)

    refresh_filtered_posts(socket, post_ids)
  end

  def interaction_refresh_post_ids(socket, message_id) do
    normalized_message_id = normalize_post_id(message_id)
    filtered_posts = socket.assigns[:filtered_posts] || []
    message_lookup = build_interaction_message_lookup(socket)

    direct_post_ids =
      filtered_posts
      |> Enum.filter(fn post ->
        post.id == normalized_message_id ||
          post.shared_message_id == normalized_message_id ||
          (Ecto.assoc_loaded?(post.shared_message) && is_map(post.shared_message) &&
             post.shared_message.id == normalized_message_id)
      end)
      |> Enum.map(& &1.id)

    reply_parent_ids =
      socket.assigns[:post_replies]
      |> Kernel.||(%{})
      |> Enum.flat_map(fn {post_id, replies} ->
        if Enum.any?(replies, &reply_matches_message?(&1, normalized_message_id)) do
          [post_id]
        else
          []
        end
      end)

    ancestor_container_ids =
      filtered_posts
      |> Enum.filter(&post_references_message?(&1, normalized_message_id, message_lookup))
      |> Enum.map(& &1.id)

    (direct_post_ids ++ reply_parent_ids ++ ancestor_container_ids)
    |> Enum.uniq()
  end

  def update_cached_posts(socket, update_fn) when is_function(update_fn, 1) do
    updated_timeline_posts = update_fn.(socket.assigns[:timeline_posts] || [])
    updated_base_posts = update_fn.(socket.assigns[:base_timeline_posts] || [])

    updated_cache =
      Enum.reduce(socket.assigns[:special_view_cache] || %{}, %{}, fn {key, entry}, acc ->
        updated_entry =
          entry
          |> Map.update(:posts, [], fn
            posts when is_list(posts) -> update_fn.(posts)
            posts -> posts
          end)

        Map.put(acc, key, updated_entry)
      end)

    socket
    |> assign(:timeline_posts, updated_timeline_posts)
    |> assign(:base_timeline_posts, updated_base_posts)
    |> assign(:special_view_cache, updated_cache)
  end

  def assign_current_and_base_posts(socket, current_posts, base_posts) do
    cache_key = {
      socket.assigns[:current_filter],
      socket.assigns[:timeline_filter],
      socket.assigns[:search_query] || ""
    }

    special_view_cache = socket.assigns[:special_view_cache] || %{}
    existing_entry = Map.get(special_view_cache, cache_key, %{})

    updated_entry =
      existing_entry
      |> Map.put(:posts, current_posts)
      |> Map.put_new(:post_replies, socket.assigns[:post_replies] || %{})

    socket
    |> assign(:timeline_posts, current_posts)
    |> assign(:base_timeline_posts, base_posts)
    |> assign(:special_view_cache, Map.put(special_view_cache, cache_key, updated_entry))
  end

  def filter_posts_by_software(posts, "all"), do: posts

  def filter_posts_by_software(posts, "local") do
    Enum.filter(posts, fn post -> !post.federated end)
  end

  def filter_posts_by_software(posts, software) do
    domains =
      posts
      |> Enum.filter(
        &(&1.federated && &1.remote_actor &&
            !match?(%Ecto.Association.NotLoaded{}, &1.remote_actor))
      )
      |> Enum.map(& &1.remote_actor.domain)
      |> Enum.uniq()

    software_map = Elektrine.ActivityPub.Nodeinfo.get_software_batch(domains)

    Enum.filter(posts, fn post ->
      cond do
        !post.federated ->
          true

        post.remote_actor && !match?(%Ecto.Association.NotLoaded{}, post.remote_actor) ->
          instance_sw = Map.get(software_map, post.remote_actor.domain)
          software_matches?(instance_sw, software)

        true ->
          false
      end
    end)
  end

  def filter_posts_by_search_query(posts, query) when is_list(posts) do
    normalized_query = normalize_search_query(query)

    if normalized_query == "" do
      posts
    else
      Enum.filter(posts, &post_matches_search_query?(&1, normalized_query))
    end
  end

  def filter_posts_by_search_query(_, _), do: []

  def remove_post_from_socket(socket, post_id) do
    normalized_post_id = normalize_post_id(post_id)

    updated_recent_ids =
      Enum.reject(socket.assigns[:recently_loaded_post_ids] || [], &(&1 == normalized_post_id))

    updated_special_view_cache =
      socket.assigns[:special_view_cache]
      |> Kernel.||(%{})
      |> Enum.into(%{}, fn {key, entry} ->
        updated_entry =
          entry
          |> Map.update(:posts, [], fn posts ->
            Enum.reject(posts, &(&1.id == normalized_post_id))
          end)
          |> Map.update(:post_replies, %{}, fn replies ->
            replies
            |> Map.delete(normalized_post_id)
            |> Map.new(fn {parent_id, reply_list} ->
              {parent_id, Enum.reject(reply_list, &(Map.get(&1, :id) == normalized_post_id))}
            end)
          end)

        {key, updated_entry}
      end)

    socket
    |> update(:timeline_posts, fn posts ->
      Enum.reject(posts || [], &(&1.id == normalized_post_id))
    end)
    |> assign(
      :base_timeline_posts,
      Enum.reject(socket.assigns[:base_timeline_posts] || [], &(&1.id == normalized_post_id))
    )
    |> assign(
      :queued_posts,
      Enum.reject(socket.assigns[:queued_posts] || [], &(&1.id == normalized_post_id))
    )
    |> assign(
      :post_replies,
      remove_post_from_replies(socket.assigns[:post_replies] || %{}, normalized_post_id)
    )
    |> assign(:special_view_cache, updated_special_view_cache)
    |> assign(
      :loading_remote_replies,
      MapSet.delete(socket.assigns[:loading_remote_replies] || MapSet.new(), normalized_post_id)
    )
    |> assign(:recently_loaded_post_ids, updated_recent_ids)
    |> assign(:recently_loaded_count, length(updated_recent_ids))
    |> maybe_clear_reply_targets(normalized_post_id)
    |> apply_timeline_filter()
  end

  defp software_matches?(nil, _), do: false

  defp software_matches?(instance_sw, filter) do
    filter = String.downcase(filter)

    case filter do
      "pleroma" -> instance_sw in ["pleroma", "akkoma"]
      "misskey" -> instance_sw in ["misskey", "calckey", "firefish", "iceshrimp", "sharkey"]
      "mastodon" -> instance_sw in ["mastodon", "hometown", "glitch"]
      _ -> instance_sw == filter
    end
  end

  defp maybe_prioritize_non_community_posts(posts, socket) do
    if socket.assigns.current_filter in [
         "all",
         "explore",
         "following",
         "home",
         "federated",
         "public"
       ] &&
         socket.assigns.timeline_filter == "all" &&
         socket.assigns.software_filter == "all" do
      {non_community, community} =
        Enum.split_with(posts, fn post ->
          !PostUtilities.community_post?(post)
        end)

      non_community ++ community
    else
      posts
    end
  end

  def get_user_likes(user_id, messages) do
    message_ids = Enum.map(messages, & &1.id)
    liked_ids = Elektrine.Social.list_user_likes(user_id, message_ids)
    Map.new(liked_ids, &{&1, true})
  end

  def get_user_follows(user_id, posts) do
    local_user_ids =
      posts
      |> Enum.filter(& &1.sender_id)
      |> Enum.map(& &1.sender_id)
      |> Enum.uniq()

    local_follows =
      if Enum.empty?(local_user_ids) do
        %{}
      else
        Elektrine.Profiles.following_status_batch(user_id, local_user_ids)
        |> Enum.filter(fn {_followed_id, status} -> status == :following end)
        |> Map.new(fn {followed_id, _status} -> {{:local, followed_id}, true} end)
      end

    remote_actor_ids =
      posts
      |> Enum.filter(& &1.remote_actor_id)
      |> Enum.map(& &1.remote_actor_id)
      |> Enum.uniq()

    remote_follows =
      if Enum.empty?(remote_actor_ids) do
        %{}
      else
        Elektrine.Profiles.remote_following_status_batch(user_id, remote_actor_ids)
        |> Enum.filter(fn {_actor_id, status} -> status == :following end)
        |> Map.new(fn {actor_id, _status} -> {{:remote, actor_id}, true} end)
      end

    Map.merge(local_follows, remote_follows)
  end

  def merge_and_sort_posts(existing_posts, new_posts) do
    (existing_posts ++ new_posts)
    |> dedupe_posts()
    |> Enum.sort_by(& &1.inserted_at, {:desc, NaiveDateTime})
  end

  def dedupe_posts(posts) when is_list(posts) do
    Enum.uniq_by(posts, fn post ->
      Map.get(post, :id) ||
        Map.get(post, :activitypub_id) ||
        Map.get(post, :ap_id) ||
        inspect(post)
    end)
  end

  def dedupe_posts(_), do: []

  def get_pending_follows(user_id, posts) do
    remote_actor_ids =
      posts
      |> Enum.filter(& &1.remote_actor_id)
      |> Enum.map(& &1.remote_actor_id)
      |> Enum.uniq()

    if Enum.empty?(remote_actor_ids) do
      %{}
    else
      Elektrine.Profiles.remote_following_status_batch(user_id, remote_actor_ids)
      |> Enum.filter(fn {_actor_id, status} -> status == :pending end)
      |> Map.new(fn {actor_id, _status} -> {{:remote, actor_id}, true} end)
    end
  end

  defp ids_prefixed?(prefix_ids, full_ids) do
    prefix_length = length(prefix_ids)
    prefix_length <= length(full_ids) && Enum.take(full_ids, prefix_length) == prefix_ids
  end

  defp ids_suffixed?(suffix_ids, full_ids) do
    suffix_length = length(suffix_ids)

    suffix_length <= length(full_ids) &&
      Enum.drop(full_ids, length(full_ids) - suffix_length) == suffix_ids
  end

  defp ids_subsequence?(candidate_ids, full_ids)
       when is_list(candidate_ids) and is_list(full_ids) do
    do_ids_subsequence?(candidate_ids, full_ids)
  end

  defp do_ids_subsequence?([], _full_ids), do: true
  defp do_ids_subsequence?(_candidate_ids, []), do: false

  defp do_ids_subsequence?([candidate_id | remaining_candidates], [candidate_id | remaining_ids]) do
    do_ids_subsequence?(remaining_candidates, remaining_ids)
  end

  defp do_ids_subsequence?(candidate_ids, [_id | remaining_ids]) do
    do_ids_subsequence?(candidate_ids, remaining_ids)
  end

  defp append_filtered_posts(socket, posts) do
    Enum.reduce(posts, socket, fn post, acc ->
      stream_insert(acc, :timeline_filtered_posts, post, at: -1)
    end)
  end

  defp prepend_filtered_posts(socket, posts) do
    posts
    |> Enum.reverse()
    |> Enum.reduce(socket, fn post, acc ->
      stream_insert(acc, :timeline_filtered_posts, post, at: 0)
    end)
  end

  defp remove_filtered_posts(socket, previous_posts_by_id, post_ids) do
    Enum.reduce(post_ids, socket, fn post_id, acc ->
      case Map.get(previous_posts_by_id, post_id) do
        nil -> acc
        post -> stream_delete(acc, :timeline_filtered_posts, post)
      end
    end)
  end

  defp refresh_changed_filtered_posts(socket, posts) do
    Enum.reduce(posts, socket, fn post, acc ->
      stream_insert(acc, :timeline_filtered_posts, post, update_only: true)
    end)
  end

  defp reply_matches_message?(reply, message_id) when is_map(reply) do
    Enum.any?(
      [
        Map.get(reply, :id),
        Map.get(reply, :activitypub_id),
        Map.get(reply, :ap_id)
      ],
      fn
        nil -> false
        value -> normalize_post_id(value) == message_id
      end
    )
  end

  defp reply_matches_message?(_, _), do: false

  defp build_interaction_message_lookup(socket) do
    timeline_posts = socket.assigns[:timeline_posts] || []

    reply_posts =
      socket.assigns[:post_replies]
      |> Kernel.||(%{})
      |> Map.values()
      |> List.flatten()

    (timeline_posts ++ reply_posts)
    |> Enum.reduce(%{}, fn
      %{id: id} = post, acc when is_integer(id) -> Map.put(acc, id, post)
      _, acc -> acc
    end)
  end

  defp post_references_message?(%{id: id}, message_id, _message_lookup) when id == message_id,
    do: true

  defp post_references_message?(post, message_id, message_lookup) when is_map(post) do
    post
    |> Map.get(:reply_to_id)
    |> normalize_post_id()
    |> ancestor_chain_contains_message?(message_id, message_lookup, MapSet.new())
  end

  defp post_references_message?(_, _, _), do: false

  defp ancestor_chain_contains_message?(nil, _message_id, _message_lookup, _seen), do: false

  defp ancestor_chain_contains_message?(current_id, message_id, _message_lookup, _seen)
       when current_id == message_id,
       do: true

  defp ancestor_chain_contains_message?(current_id, message_id, message_lookup, seen) do
    normalized_current_id = normalize_post_id(current_id)

    cond do
      is_nil(normalized_current_id) ->
        false

      MapSet.member?(seen, normalized_current_id) ->
        false

      true ->
        next_seen = MapSet.put(seen, normalized_current_id)

        case fetch_interaction_message(message_lookup, normalized_current_id) do
          %{reply_to_id: reply_to_id} ->
            ancestor_chain_contains_message?(
              normalize_post_id(reply_to_id),
              message_id,
              message_lookup,
              next_seen
            )

          _ ->
            false
        end
    end
  end

  defp fetch_interaction_message(message_lookup, message_id) do
    case Map.get(message_lookup, message_id) do
      nil -> MessagingMessages.get_message(message_id)
      message -> message
    end
  end

  defp normalize_post_id(post_id) when is_integer(post_id), do: post_id

  defp normalize_post_id(post_id) when is_binary(post_id) do
    case Integer.parse(post_id) do
      {id, ""} -> id
      _ -> post_id
    end
  end

  defp normalize_post_id(post_id), do: post_id

  defp normalize_search_query(query) when is_binary(query), do: String.trim(query)
  defp normalize_search_query(_), do: ""

  defp post_matches_search_query?(post, normalized_query) do
    sender = Map.get(post, :sender)
    remote_actor = Map.get(post, :remote_actor)

    searchable_values =
      [
        Map.get(post, :content),
        Map.get(post, :title),
        (is_map(sender) && Map.get(sender, :username)) || nil,
        (is_map(sender) && Map.get(sender, :display_name)) || nil,
        (is_map(remote_actor) && Map.get(remote_actor, :username)) || nil,
        (is_map(remote_actor) && Map.get(remote_actor, :display_name)) || nil,
        (is_map(remote_actor) && Map.get(remote_actor, :domain)) || nil
      ]

    Enum.any?(searchable_values, fn
      value when is_binary(value) ->
        value
        |> String.downcase()
        |> String.contains?(normalized_query)

      _ ->
        false
    end)
  end

  defp remove_post_from_replies(replies_by_post_id, normalized_post_id) do
    replies_by_post_id
    |> Map.delete(normalized_post_id)
    |> Map.new(fn {parent_id, replies} ->
      {parent_id, Enum.reject(replies, &(Map.get(&1, :id) == normalized_post_id))}
    end)
  end

  defp maybe_clear_reply_targets(socket, normalized_post_id) do
    socket
    |> maybe_clear_reply_to_post(normalized_post_id)
    |> maybe_clear_reply_to_reply(normalized_post_id)
  end

  defp maybe_clear_reply_to_post(socket, normalized_post_id) do
    case socket.assigns[:reply_to_post] do
      %{id: ^normalized_post_id} ->
        socket
        |> assign(:reply_to_post, nil)
        |> assign(:reply_to_post_recent_replies, [])
        |> assign(:reply_content, "")

      _ ->
        socket
    end
  end

  defp maybe_clear_reply_to_reply(socket, normalized_post_id) do
    if socket.assigns[:reply_to_reply_id] == normalized_post_id do
      socket
      |> assign(:reply_to_reply_id, nil)
      |> assign(:reply_content, "")
    else
      socket
    end
  end
end
