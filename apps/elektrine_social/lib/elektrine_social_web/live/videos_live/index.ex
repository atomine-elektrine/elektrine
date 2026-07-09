defmodule ElektrineSocialWeb.VideosLive.Index do
  use ElektrineSocialWeb, :live_view

  import Ecto.Query, except: [update: 2, update: 3]
  import ElektrineSocialWeb.Components.Platform.ENav

  import ElektrineWeb.HtmlHelpers,
    only: [actor_display_name_text: 1, plain_text_content: 1]

  import ElektrineWeb.Live.Helpers.PostStateHelpers
  import ElektrineWeb.Live.NotificationHelpers

  alias Elektrine.PubSubTopics
  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Message
  alias ElektrineSocialWeb.Components.Social.PostUtilities

  @videos_page_size 60
  @video_metadata_pattern ~S<"(type|mediaType|media_type)"\s*:\s*"(video|video/[^"]+)">
  @video_url_pattern "\\.(mp4|webm|ogv|mov)(\\?.*)?$"

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user]
    locale = session["locale"] || (user && user.locale) || "en"
    Gettext.put_locale(ElektrineWeb.Gettext, locale)

    if connected?(socket) && Elektrine.RuntimeEnv.environment() != :test do
      PubSubTopics.subscribe(PubSubTopics.timeline_public())
      send(self(), :load_videos_data)
    end

    socket =
      socket
      |> assign(:page_title, "Videos")
      |> assign(:video_posts, [])
      |> assign(:filtered_posts, [])
      |> assign(:current_filter, "discover")
      |> assign(:video_search, "")
      |> assign(:video_sort, "fresh")
      |> assign(:software_filter, "all")
      |> assign(:user_likes, MapSet.new())
      |> assign(:user_saved_posts, MapSet.new())
      |> assign(:loading_videos, true)
      |> assign(:loading_more, false)
      |> assign(:videos_load_ref, nil)
      |> assign(:end_of_feed, false)

    socket =
      if Elektrine.RuntimeEnv.environment() == :test do
        start_videos_load(socket, socket.assigns.current_filter)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    search = normalize_video_search(params["q"])

    if search == socket.assigns.video_search do
      {:noreply, socket}
    else
      {:noreply, socket |> assign(:video_search, search) |> apply_video_filter()}
    end
  end

  @impl true
  def handle_event("set_filter", %{"filter" => filter}, socket) do
    if socket.assigns.current_filter == filter do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:current_filter, filter)
       |> assign(:loading_videos, true)
       |> assign(:loading_more, false)
       |> assign(:end_of_feed, false)
       |> start_videos_load(filter)}
    end
  end

  def handle_event("set_software_filter", %{"software" => software}, socket) do
    if socket.assigns.software_filter == software do
      {:noreply, socket}
    else
      {:noreply, socket |> assign(:software_filter, software) |> apply_video_filter()}
    end
  end

  def handle_event("set_video_sort", %{"sort" => sort}, socket) do
    if socket.assigns.video_sort == sort do
      {:noreply, socket}
    else
      {:noreply, socket |> assign(:video_sort, sort) |> apply_video_filter()}
    end
  end

  def handle_event("search_videos", %{"query" => query}, socket) do
    {:noreply, push_patch(socket, to: videos_search_path(query))}
  end

  def handle_event("clear_video_search", _params, socket) do
    {:noreply, push_patch(socket, to: videos_search_path(""))}
  end

  def handle_event("like_video", %{"video_id" => video_id}, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id

      case parse_positive_int(video_id) do
        {:ok, video_id} ->
          toggle_video_like(socket, user_id, video_id)

        :error ->
          {:noreply, notify_error(socket, "Failed to like video")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to like videos")}
    end
  end

  def handle_event("save_post", %{"video_id" => video_id}, socket) do
    handle_event("save_post", %{"message_id" => video_id}, socket)
  end

  def handle_event("save_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id

      case parse_positive_int(message_id) do
        {:ok, video_id} ->
          case Social.save_post(user_id, video_id) do
            {:ok, _} ->
              {:noreply, socket |> update(:user_saved_posts, &MapSet.put(&1, video_id))}

            {:error, _} ->
              {:noreply, socket |> update(:user_saved_posts, &MapSet.put(&1, video_id))}
          end

        :error ->
          {:noreply, notify_error(socket, "Failed to save video")}
      end
    else
      {:noreply, notify_error(socket, "You must be signed in to save videos")}
    end
  end

  def handle_event("unsave_post", %{"video_id" => video_id}, socket) do
    handle_event("unsave_post", %{"message_id" => video_id}, socket)
  end

  def handle_event("unsave_post", %{"message_id" => message_id}, socket) do
    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id

      case parse_positive_int(message_id) do
        {:ok, video_id} ->
          case Social.unsave_post(user_id, video_id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> update(:user_saved_posts, &MapSet.delete(&1, video_id))
               |> maybe_remove_from_collection_filter("saved", video_id)
               |> apply_video_filter()}

            {:error, _} ->
              {:noreply,
               socket
               |> update(:user_saved_posts, &MapSet.delete(&1, video_id))
               |> maybe_remove_from_collection_filter("saved", video_id)
               |> apply_video_filter()}
          end

        :error ->
          {:noreply, notify_error(socket, "Failed to unsave video")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("load-more", _params, socket) do
    if socket.assigns.loading_more || socket.assigns.end_of_feed do
      {:noreply, socket}
    else
      current_posts = socket.assigns.video_posts
      before_timestamp = current_posts |> List.last() |> then(&(&1 && &1.inserted_at))
      socket = assign(socket, :loading_more, true)

      more_posts =
        get_video_feed(socket.assigns.current_filter, socket.assigns.current_user,
          before_timestamp: before_timestamp
        )

      existing_ids = MapSet.new(current_posts, & &1.id)
      more_posts = Enum.reject(more_posts, &MapSet.member?(existing_ids, &1.id))
      end_of_feed = Enum.empty?(more_posts)

      {new_likes, new_saved_posts} =
        load_video_engagement_state(socket.assigns.current_user, more_posts)

      {:noreply,
       socket
       |> assign(:loading_more, false)
       |> assign(:end_of_feed, end_of_feed)
       |> assign(:user_likes, MapSet.union(socket.assigns.user_likes, new_likes))
       |> assign(
         :user_saved_posts,
         MapSet.union(socket.assigns.user_saved_posts, new_saved_posts)
       )
       |> update(:video_posts, &(&1 ++ more_posts))
       |> apply_video_filter()}
    end
  end

  @impl true
  def handle_info(:load_videos_data, socket) do
    {:noreply, start_videos_load(socket, socket.assigns.current_filter)}
  end

  def handle_info({:videos_data_loaded, load_ref, data}, socket) do
    cond do
      load_ref != socket.assigns.videos_load_ref ->
        {:noreply, socket}

      data.filter != socket.assigns.current_filter ->
        {:noreply, start_videos_load(socket, socket.assigns.current_filter)}

      true ->
        {:noreply, apply_videos_data(socket, data)}
    end
  end

  def handle_info(_info, socket), do: {:noreply, socket}

  defp toggle_video_like(socket, user_id, video_id) do
    currently_liked = MapSet.member?(socket.assigns.user_likes, video_id)

    if currently_liked do
      case Social.unlike_post(user_id, video_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> update(:user_likes, &MapSet.delete(&1, video_id))
           |> update(:video_posts, &update_video_like_count(&1, video_id, -1))
           |> maybe_remove_from_collection_filter("liked", video_id)
           |> apply_video_filter()}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to unlike video")}
      end
    else
      case Social.like_post(user_id, video_id) do
        {:ok, _} ->
          {:noreply,
           socket
           |> update(:user_likes, &MapSet.put(&1, video_id))
           |> update(:video_posts, &update_video_like_count(&1, video_id, 1))
           |> apply_video_filter()}

        {:error, _} ->
          {:noreply, notify_error(socket, "Failed to like video")}
      end
    end
  end

  defp parse_positive_int(value) do
    case Integer.parse(to_string(value)) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp start_videos_load(socket, filter) do
    load_ref = System.unique_integer([:positive, :monotonic])
    user = socket.assigns[:current_user]
    parent = self()

    socket = socket |> assign(:videos_load_ref, load_ref) |> assign(:loading_videos, true)

    if Elektrine.RuntimeEnv.environment() == :test do
      apply_videos_data(socket, build_videos_data(filter, user))
    else
      Task.start(fn ->
        send(parent, {:videos_data_loaded, load_ref, build_videos_data(filter, user)})
      end)

      socket
    end
  end

  defp build_videos_data(filter, user) do
    video_posts = get_video_feed_page(filter, user)
    {user_likes, user_saved_posts} = load_video_engagement_state(user, video_posts)

    %{
      filter: filter,
      video_posts: video_posts,
      user_likes: user_likes,
      user_saved_posts: user_saved_posts,
      end_of_feed: length(video_posts) < @videos_page_size
    }
  end

  # The discover/trending feeds are global, so the first page can be served
  # from a short-lived cache instead of re-running the feed query per visit.
  # Per-user engagement state is always computed fresh from the posts.
  defp get_video_feed_page(filter, user) when filter in ["discover", "trending"] do
    ElektrineSocialWeb.Live.GlobalFeedPage.fetch({:videos, filter}, fn ->
      get_video_feed(filter, user)
    end)
  end

  defp get_video_feed_page(filter, user), do: get_video_feed(filter, user)

  defp apply_videos_data(socket, data) do
    socket
    |> assign(:video_posts, data.video_posts)
    |> assign(:filtered_posts, data.video_posts)
    |> assign(:user_likes, data.user_likes)
    |> assign(:user_saved_posts, data.user_saved_posts)
    |> assign(:loading_videos, false)
    |> assign(:end_of_feed, data.end_of_feed)
    |> apply_video_filter()
  end

  defp get_video_feed(filter, user, opts \\ [])

  defp get_video_feed("discover", _user, opts) do
    before_naive = normalize_to_naive(Keyword.get(opts, :before_timestamp))
    limit = Keyword.get(opts, :limit, @videos_page_size)

    Message
    |> visible_video_base_query(["public", "unlisted"])
    |> maybe_before(before_naive)
    |> order_by([m], desc: m.inserted_at)
    |> limit(^(limit * 4))
    |> preload([:link_preview, sender: [:profile], remote_actor: []])
    |> Repo.all()
    |> Enum.filter(&video_post?/1)
    |> Enum.take(limit)
  end

  defp get_video_feed("following", user, opts) do
    if user do
      before_naive = normalize_to_naive(Keyword.get(opts, :before_timestamp))
      limit = Keyword.get(opts, :limit, @videos_page_size)

      following_user_ids = following_user_ids(user)
      following_remote_actor_ids = following_remote_actor_ids(user)

      local_query =
        Message
        |> visible_video_base_query(["public", "unlisted", "followers"])
        |> where([m], m.sender_id in ^following_user_ids)

      remote_query =
        Message
        |> visible_video_base_query(["public", "unlisted", "followers"])
        |> where([m], m.remote_actor_id in ^following_remote_actor_ids)

      [local_query, remote_query]
      |> Enum.flat_map(fn query ->
        query
        |> maybe_before(before_naive)
        |> order_by([m], desc: m.inserted_at)
        |> limit(^(limit * 3))
        |> preload([:link_preview, sender: [:profile], remote_actor: []])
        |> Repo.all()
      end)
      |> Enum.uniq_by(& &1.id)
      |> Enum.filter(&video_post?/1)
      |> sort_video_posts("fresh")
      |> Enum.take(limit)
    else
      get_video_feed("discover", nil, opts)
    end
  end

  defp get_video_feed("liked", user, opts) do
    collection_video_feed(user, opts, :liked)
  end

  defp get_video_feed("saved", user, opts) do
    collection_video_feed(user, opts, :saved)
  end

  defp get_video_feed("trending", _user, opts) do
    before_naive = normalize_to_naive(Keyword.get(opts, :before_timestamp))
    limit = Keyword.get(opts, :limit, @videos_page_size)

    Message
    |> visible_video_base_query(["public", "unlisted"])
    |> maybe_before(before_naive)
    |> order_by([m], desc: m.like_count, desc: m.inserted_at)
    |> limit(^(limit * 4))
    |> preload([:link_preview, sender: [:profile], remote_actor: []])
    |> Repo.all()
    |> Enum.filter(&video_post?/1)
    |> Enum.take(limit)
  end

  defp get_video_feed(_, _user, opts), do: get_video_feed("discover", nil, opts)

  defp collection_video_feed(nil, _opts, _collection), do: []

  defp collection_video_feed(user, opts, collection) do
    before_naive = normalize_to_naive(Keyword.get(opts, :before_timestamp))
    limit = Keyword.get(opts, :limit, @videos_page_size)

    query =
      case collection do
        :liked ->
          from(m in visible_video_base_query(Message, ["public", "unlisted", "followers"]),
            join: l in Elektrine.Social.PostLike,
            on: l.message_id == m.id,
            where: l.user_id == ^user.id,
            order_by: [desc: l.created_at, desc: m.inserted_at]
          )

        :saved ->
          from(m in visible_video_base_query(Message, ["public", "unlisted", "followers"]),
            join: s in Elektrine.Social.SavedItem,
            on: s.message_id == m.id,
            where: s.user_id == ^user.id,
            order_by: [desc: s.inserted_at, desc: m.inserted_at]
          )
      end

    query
    |> maybe_before(before_naive)
    |> limit(^(limit * 4))
    |> preload([:link_preview, sender: [:profile], remote_actor: []])
    |> Repo.all()
    |> Enum.filter(&(can_view_video_post?(&1, user) && video_post?(&1)))
    |> Enum.take(limit)
  end

  defp visible_video_base_query(queryable, visibilities) do
    from(m in queryable,
      where:
        m.visibility in ^visibilities and is_nil(m.deleted_at) and is_nil(m.reply_to_id) and
          fragment("array_length(?, 1)", m.media_urls) > 0 and
          (fragment("coalesce(?->>'type', '') ILIKE 'video'", m.media_metadata) or
             fragment("?::text ~* ?", m.media_metadata, ^@video_metadata_pattern) or
             fragment(
               "EXISTS (SELECT 1 FROM unnest(?) AS media_url WHERE media_url ~* ?)",
               m.media_urls,
               ^@video_url_pattern
             ))
    )
  end

  defp maybe_before(query, nil), do: query

  defp maybe_before(query, before_naive),
    do: from(m in query, where: m.inserted_at < ^before_naive)

  defp following_user_ids(user) do
    ids =
      from(f in Elektrine.Profiles.Follow,
        where: f.follower_id == ^user.id and not is_nil(f.followed_id),
        select: f.followed_id
      )
      |> Repo.all()

    [user.id | ids] |> Enum.uniq()
  end

  defp following_remote_actor_ids(user) do
    from(f in Elektrine.Profiles.Follow,
      where: f.follower_id == ^user.id and not is_nil(f.remote_actor_id) and f.pending == false,
      select: f.remote_actor_id
    )
    |> Repo.all()
  end

  defp load_video_engagement_state(nil, _posts), do: {MapSet.new(), MapSet.new()}
  defp load_video_engagement_state(_user, []), do: {MapSet.new(), MapSet.new()}

  defp load_video_engagement_state(user, posts) do
    {get_user_likes_set(user.id, posts),
     Social.list_user_saved_posts(user.id, Enum.map(posts, & &1.id))}
  end

  defp get_user_likes_set(user_id, posts) do
    user_id
    |> get_user_likes(posts)
    |> Enum.reduce(MapSet.new(), fn
      {message_id, true}, liked_ids -> MapSet.put(liked_ids, message_id)
      {_message_id, false}, liked_ids -> liked_ids
    end)
  end

  defp apply_video_filter(socket) do
    filtered_posts =
      socket.assigns.video_posts
      |> filter_posts_by_software(socket.assigns.software_filter)
      |> filter_posts_by_search(socket.assigns.video_search)
      |> sort_video_posts(socket.assigns.video_sort)

    assign(socket, :filtered_posts, filtered_posts)
  end

  defp videos_search_path(query) do
    case normalize_video_search(query) do
      "" -> "/videos"
      search -> "/videos?#{URI.encode_query(%{"q" => search})}"
    end
  end

  defp normalize_video_search(query) when is_binary(query), do: String.trim(query)
  defp normalize_video_search(_), do: ""

  defp filter_posts_by_search(posts, query) when query in [nil, ""], do: posts

  defp filter_posts_by_search(posts, query) do
    normalized_query = String.downcase(String.trim(query))

    Enum.filter(posts, fn post ->
      searchable_terms =
        [
          video_plain_text(post.title),
          video_plain_text(post.content),
          video_creator_name(post),
          video_creator_handle(post),
          video_source_label(post)
        ]
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.downcase/1)

      Enum.any?(searchable_terms, &String.contains?(&1, normalized_query))
    end)
  end

  defp filter_posts_by_software(posts, "all"), do: posts
  defp filter_posts_by_software(posts, "local"), do: Enum.filter(posts, &(!&1.federated))

  defp filter_posts_by_software(posts, software) do
    domains =
      posts
      |> Enum.filter(&(&1.federated && &1.remote_actor && Ecto.assoc_loaded?(&1.remote_actor)))
      |> Enum.map(& &1.remote_actor.domain)
      |> Enum.uniq()

    software_map = Elektrine.ActivityPub.Nodeinfo.get_software_batch(domains)

    Enum.filter(posts, fn post ->
      if post.federated && post.remote_actor && Ecto.assoc_loaded?(post.remote_actor) do
        software_matches?(Map.get(software_map, post.remote_actor.domain), software)
      else
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

  defp sort_video_posts(posts, "popular") do
    Enum.sort_by(posts, &{-video_like_score(&1), -video_inserted_at_unix(&1)}, :asc)
  end

  defp sort_video_posts(posts, "discussed") do
    Enum.sort_by(
      posts,
      &{-(Map.get(&1, :reply_count, 0) || 0), -video_inserted_at_unix(&1)},
      :asc
    )
  end

  defp sort_video_posts(posts, _sort), do: Enum.sort_by(posts, &video_inserted_at_unix/1, :desc)

  defp update_video_like_count(posts, video_id, delta) do
    Enum.map(posts, fn post ->
      if post.id == video_id,
        do: %{post | like_count: max(0, (post.like_count || 0) + delta)},
        else: post
    end)
  end

  defp maybe_remove_from_collection_filter(socket, filter, video_id) do
    if socket.assigns.current_filter == filter do
      update(socket, :video_posts, fn posts -> Enum.reject(posts, &(&1.id == video_id)) end)
    else
      socket
    end
  end

  defp video_post?(post) do
    video_metadata?(post) || Enum.any?(post.media_urls || [], &PostUtilities.video_url?/1)
  end

  defp video_metadata?(post) do
    metadata = Map.get(post, :media_metadata) || %{}

    metadata_type = metadata_value(metadata, ["type", :type]) |> to_string() |> String.downcase()

    metadata_type == "video" ||
      metadata_attachments(metadata)
      |> Enum.any?(fn attachment ->
        attachment_type =
          metadata_value(attachment, ["type", :type]) |> to_string() |> String.downcase()

        media_type =
          metadata_value(attachment, ["mediaType", :mediaType, "media_type", :media_type])

        attachment_type == "video" || video_media_type?(media_type)
      end)
  end

  defp video_primary_url(post) do
    metadata = Map.get(post, :media_metadata) || %{}

    metadata_url =
      metadata
      |> metadata_attachments()
      |> Enum.find_value(fn attachment ->
        media_type =
          metadata_value(attachment, ["mediaType", :mediaType, "media_type", :media_type])

        type = metadata_value(attachment, ["type", :type]) |> to_string() |> String.downcase()

        if type == "video" || video_media_type?(media_type) do
          metadata_value(attachment, ["url", :url, "remote_url", :remote_url])
        end
      end)

    [metadata_url | post.media_urls || []]
    |> Enum.filter(&video_url_candidate?/1)
    |> Enum.map(&video_attachment_url(&1, post))
    |> Enum.find(fn url ->
      is_binary(url) && (PostUtilities.video_url?(url) || video_metadata?(post))
    end)
  end

  defp video_thumbnail_url(post) do
    metadata = Map.get(post, :media_metadata) || %{}

    attachment_thumbnail =
      metadata
      |> metadata_attachments()
      |> Enum.find_value(fn attachment ->
        metadata_value(attachment, [
          "preview_url",
          :preview_url,
          "previewUrl",
          :previewUrl,
          "thumbnail_url",
          :thumbnail_url,
          "thumbnailUrl",
          :thumbnailUrl,
          "sensitiveThumbnailUrl",
          :sensitiveThumbnailUrl,
          "poster",
          :poster,
          "preview",
          :preview,
          "image",
          :image
        ])
      end)

    link_preview_thumbnail =
      case Map.get(post, :link_preview) do
        %{image_url: image_url} when is_binary(image_url) -> image_url
        _ -> nil
      end

    [
      metadata_value(metadata, [
        "thumbnail_url",
        :thumbnail_url,
        "thumbnailUrl",
        :thumbnailUrl,
        "preview_url",
        :preview_url,
        "preview",
        :preview,
        "poster",
        :poster,
        "image",
        :image,
        "icon",
        :icon
      ]),
      attachment_thumbnail,
      link_preview_thumbnail
    ]
    |> Enum.find_value(fn candidate ->
      candidate
      |> thumbnail_candidate_url()
      |> normalize_thumbnail_url(post)
    end)
  end

  defp thumbnail_candidate_url(value) when is_binary(value), do: value

  defp thumbnail_candidate_url(value) when is_list(value) do
    Enum.find_value(value, &thumbnail_candidate_url/1)
  end

  defp thumbnail_candidate_url(value) when is_map(value) do
    metadata_value(value, ["url", :url, "href", :href, "src", :src])
    |> thumbnail_candidate_url()
  end

  defp thumbnail_candidate_url(_), do: nil

  defp normalize_thumbnail_url(nil, _post), do: nil

  defp normalize_thumbnail_url(url, post) do
    url
    |> video_attachment_url(post)
    |> PostUtilities.safe_image_url()
  end

  defp metadata_attachments(metadata) when is_map(metadata) do
    case metadata_value(metadata, [
           "media_attachments",
           :media_attachments,
           "attachments",
           :attachments
         ]) do
      attachments when is_list(attachments) -> Enum.filter(attachments, &is_map/1)
      _ -> []
    end
  end

  defp metadata_attachments(_), do: []

  defp metadata_value(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp metadata_value(_, _), do: nil

  defp video_media_type?(media_type) when is_binary(media_type) do
    media_type = String.downcase(media_type)

    String.starts_with?(media_type, "video/") ||
      media_type in ["application/x-mpegurl", "application/vnd.apple.mpegurl"]
  end

  defp video_media_type?(_), do: false

  defp video_url_candidate?(url) when is_binary(url), do: String.trim(url) != ""
  defp video_url_candidate?(_), do: false

  defp video_attachment_url(url, %{federated: true}) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]),
      do: url,
      else: Elektrine.Uploads.attachment_url(url)
  end

  defp video_attachment_url(url, post), do: Elektrine.Uploads.attachment_url(url, post)

  defp video_sensitive?(post) when is_map(post) do
    Elektrine.Strings.present?(Map.get(post, :content_warning)) ||
      Map.get(post, :sensitive) == true || Map.get(post, "sensitive") == true
  end

  defp video_post_path(%{id: id}) when is_integer(id), do: Elektrine.Paths.remote_post_path(id)
  defp video_post_path(post), do: Elektrine.Paths.post_path(post)

  defp video_display_title(post) do
    title = video_plain_text(post.title)
    content = video_plain_text(post.content)

    cond do
      Elektrine.Strings.present?(title) -> title
      Elektrine.Strings.present?(content) -> String.slice(content, 0, 80)
      true -> "Video post"
    end
  end

  defp video_plain_text(nil), do: ""
  defp video_plain_text(""), do: ""
  defp video_plain_text(text) when is_binary(text), do: plain_text_content(text)
  defp video_plain_text(_), do: ""

  defp video_creator_name(post) do
    cond do
      post.sender && Ecto.assoc_loaded?(post.sender) ->
        actor_display_name_text(post.sender)

      post.remote_actor && Ecto.assoc_loaded?(post.remote_actor) ->
        actor_display_name_text(post.remote_actor)

      true ->
        nil
    end
  end

  defp video_creator_handle(post) do
    cond do
      post.sender && Ecto.assoc_loaded?(post.sender) ->
        "@#{post.sender.handle || post.sender.username}"

      post.remote_actor && Ecto.assoc_loaded?(post.remote_actor) ->
        "@#{post.remote_actor.username}@#{post.remote_actor.domain}"

      true ->
        nil
    end
  end

  defp video_source_label(post) do
    cond do
      post.federated && post.remote_actor && Ecto.assoc_loaded?(post.remote_actor) ->
        post.remote_actor.domain || "Fediverse"

      post.federated ->
        "Fediverse"

      true ->
        "Local"
    end
  end

  defp video_empty_state(assigns) do
    cond do
      assigns.video_search != "" ->
        {"No videos match that search", "Try another title, creator, source, or keyword."}

      assigns.current_filter == "following" ->
        {"No videos from people you follow yet",
         "Follow PeerTube channels and video creators to fill this feed."}

      assigns.current_filter == "liked" ->
        {"No liked videos yet", "Heart a few videos and they will show up here."}

      assigns.current_filter == "saved" ->
        {"Your saved videos are empty", "Bookmark videos to build a personal watch list."}

      assigns.current_filter == "trending" ->
        {"No trending videos yet", "Popular federated videos will appear here once they arrive."}

      true ->
        {"No videos yet", "PeerTube and other federated videos will appear here as they arrive."}
    end
  end

  defp format_video_count(value) when is_integer(value) and value >= 1_000_000,
    do: "#{Float.round(value / 1_000_000, 1)}M"

  defp format_video_count(value) when is_integer(value) and value >= 1_000,
    do: "#{Float.round(value / 1_000, 1)}K"

  defp format_video_count(value) when is_integer(value), do: Integer.to_string(value)
  defp format_video_count(_), do: "0"

  defp video_like_score(post), do: post.like_count || 0

  defp video_inserted_at_unix(post) do
    case post.inserted_at do
      %DateTime{} = dt -> DateTime.to_unix(dt)
      %NaiveDateTime{} = ndt -> DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_unix()
      _ -> 0
    end
  end

  defp normalize_to_naive(nil), do: nil
  defp normalize_to_naive(%NaiveDateTime{} = ndt), do: ndt
  defp normalize_to_naive(%DateTime{} = dt), do: DateTime.to_naive(dt)
  defp normalize_to_naive(_), do: nil

  defp can_view_video_post?(post, user) do
    owner? = user && post.sender_id == user.id

    case post.visibility do
      "public" ->
        true

      "unlisted" ->
        true

      "followers" ->
        owner? ||
          (user && post.sender_id && Elektrine.Profiles.following?(user.id, post.sender_id))

      "friends" ->
        owner? ||
          (user && post.sender_id && Elektrine.Friends.are_friends?(user.id, post.sender_id))

      "private" ->
        owner?

      _ ->
        false
    end
  end
end
