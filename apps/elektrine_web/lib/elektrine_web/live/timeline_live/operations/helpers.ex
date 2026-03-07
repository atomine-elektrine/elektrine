defmodule ElektrineWeb.TimelineLive.Operations.Helpers do
  @moduledoc """
  Shared helper functions for timeline operation modules.
  """

  import Phoenix.Component
  import Phoenix.LiveView
  alias ElektrineWeb.Components.Social.PostUtilities

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

    socket =
      socket
      |> assign(:filtered_posts, filtered_posts)
      |> assign(:filtered_post_ids, current_ids)

    cond do
      previous_ids == current_ids ->
        changed_posts =
          Enum.filter(filtered_posts, fn post ->
            Map.get(previous_posts_by_id, post.id) != post
          end)

        Enum.reduce(changed_posts, socket, fn post, acc ->
          stream_insert(acc, :timeline_filtered_posts, post)
        end)

      ids_prefixed?(previous_ids, current_ids) ->
        appended_posts = Enum.drop(filtered_posts, length(previous_ids))

        Enum.reduce(appended_posts, socket, fn post, acc ->
          stream_insert(acc, :timeline_filtered_posts, post, at: -1)
        end)

      true ->
        stream(socket, :timeline_filtered_posts, filtered_posts, reset: true)
    end
  end

  def assign_filtered_posts(socket, _), do: assign_filtered_posts(socket, [])

  def refresh_filtered_posts_stream(socket) do
    stream(socket, :timeline_filtered_posts, socket.assigns[:filtered_posts] || [], reset: true)
  end

  def refresh_filtered_posts(socket, post_ids) when is_list(post_ids) do
    post_ids
    |> Enum.uniq()
    |> Enum.reduce(socket, fn post_id, acc -> refresh_filtered_post(acc, post_id) end)
  end

  def refresh_filtered_posts(socket, _), do: socket

  def refresh_filtered_post(socket, post_id) do
    normalized_post_id = normalize_post_id(post_id)

    case Enum.find(socket.assigns[:filtered_posts] || [], fn post ->
           post.id == normalized_post_id
         end) do
      nil ->
        socket

      post ->
        stream_insert(socket, :timeline_filtered_posts, post)
    end
  end

  def refresh_posts_for_remote_actor(socket, remote_actor_id) do
    post_ids =
      socket.assigns[:filtered_posts]
      |> Kernel.||([])
      |> Enum.filter(&(&1.remote_actor_id == remote_actor_id))
      |> Enum.map(& &1.id)

    refresh_filtered_posts(socket, post_ids)
  end

  def refresh_posts_for_sender(socket, sender_id) do
    post_ids =
      socket.assigns[:filtered_posts]
      |> Kernel.||([])
      |> Enum.filter(&(&1.sender_id == sender_id))
      |> Enum.map(& &1.id)

    refresh_filtered_posts(socket, post_ids)
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
          false

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
