defmodule ElektrineWeb.TimelineLive.Operations.Helpers do
  @moduledoc """
  Shared helper functions for timeline operation modules.
  """

  import Phoenix.Component
  alias ElektrineWeb.Components.Social.PostUtilities

  # Apply timeline filter to socket
  def apply_timeline_filter(socket) do
    filtered_posts =
      case socket.assigns.timeline_filter do
        "posts" ->
          Enum.filter(socket.assigns.timeline_posts, fn post ->
            is_nil(Map.get(post, :reply_to_id)) &&
              !PostUtilities.has_community_uri?(post)
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
            PostUtilities.has_community_uri?(post)
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

    filtered_posts = filter_posts_by_software(filtered_posts, socket.assigns.software_filter)
    filtered_posts = maybe_prioritize_non_community_posts(filtered_posts, socket)
    assign(socket, :filtered_posts, filtered_posts)
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
    if socket.assigns.current_filter in ["all", "following", "federated", "public"] &&
         socket.assigns.timeline_filter == "all" &&
         socket.assigns.software_filter == "all" do
      {non_community, community} =
        Enum.split_with(posts, fn post ->
          !PostUtilities.has_community_uri?(post)
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
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.inserted_at, {:desc, NaiveDateTime})
  end

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
end
