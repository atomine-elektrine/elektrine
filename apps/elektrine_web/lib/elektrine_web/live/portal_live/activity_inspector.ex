defmodule ElektrineWeb.PortalLive.ActivityInspector do
  @moduledoc false

  import Ecto.Query

  alias Elektrine.Profiles
  alias Elektrine.Repo
  alias ElektrineWeb.Components.Social.PostUtilities

  @page_size 25
  @sections ~w(posts timeline gallery discussions likes followers following)

  def page_size, do: @page_size

  def default do
    %{
      section: nil,
      title: nil,
      empty_message: nil,
      entries: [],
      query: "",
      offset: 0,
      no_more: false,
      stat_value: 0
    }
  end

  def build(user_id, section, personal_stats, opts \\ []) do
    section = normalize_section(section)
    limit = Keyword.get(opts, :limit, @page_size)
    query = Keyword.get(opts, :query, "")
    entries = list_entries(user_id, section, offset: 0, limit: limit, query: query)

    %{
      section: section,
      title: section_title(section),
      empty_message: section_empty_message(section),
      entries: entries,
      query: query,
      offset: length(entries),
      no_more: length(entries) < limit,
      stat_value: section_stat_value(section, personal_stats)
    }
  end

  def normalize_section(section) when section in @sections, do: section
  def normalize_section(_section), do: "posts"

  def section_title("posts"), do: "My Posts"
  def section_title("timeline"), do: "Timeline"
  def section_title("gallery"), do: "Gallery"
  def section_title("discussions"), do: "Discuss"
  def section_title("likes"), do: "Likes"
  def section_title("followers"), do: "Followers"
  def section_title("following"), do: "Following"

  def section_empty_message("posts"), do: "No posts yet"
  def section_empty_message("timeline"), do: "No timeline posts yet"
  def section_empty_message("gallery"), do: "No gallery posts yet"
  def section_empty_message("discussions"), do: "No discussion posts yet"
  def section_empty_message("likes"), do: "No liked posts to show yet"
  def section_empty_message("followers"), do: "No followers yet"
  def section_empty_message("following"), do: "Not following anyone yet"

  def section_stat_value("posts", stats), do: Map.get(stats, :total_posts, 0)
  def section_stat_value("timeline", stats), do: Map.get(stats, :timeline_posts, 0)
  def section_stat_value("gallery", stats), do: Map.get(stats, :gallery_posts, 0)
  def section_stat_value("discussions", stats), do: Map.get(stats, :discussion_posts, 0)
  def section_stat_value("likes", stats), do: Map.get(stats, :total_likes, 0)
  def section_stat_value("followers", stats), do: Map.get(stats, :followers, 0)
  def section_stat_value("following", stats), do: Map.get(stats, :following, 0)

  def list_entries(user_id, section, opts) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit, @page_size)
    query = Keyword.get(opts, :query, "")

    case section do
      "posts" ->
        list_posts(user_id, ["post", "gallery", "discussion"], offset, limit, query)

      "timeline" ->
        list_posts(user_id, ["post"], offset, limit, query)

      "gallery" ->
        list_posts(user_id, ["gallery"], offset, limit, query)

      "discussions" ->
        list_posts(user_id, ["discussion"], offset, limit, query)

      "likes" ->
        list_likes(user_id, offset, limit, query)

      "followers" ->
        list_relationships(user_id, :followers, offset, limit, query)

      "following" ->
        list_relationships(user_id, :following, offset, limit, query)
    end
  end

  defp list_posts(user_id, post_types, offset, limit, query) do
    search_term = search_pattern(query)

    from(m in Elektrine.Social.Message,
      where:
        m.sender_id == ^user_id and m.post_type in ^post_types and is_nil(m.deleted_at) and
          m.is_draft == false,
      where:
        ^is_nil(search_term) or ilike(fragment("coalesce(?, '')", m.title), ^search_term) or
          ilike(fragment("coalesce(?, '')", m.content), ^search_term),
      order_by: [desc: m.inserted_at],
      offset: ^offset,
      limit: ^limit,
      preload: [:conversation]
    )
    |> Repo.all()
    |> Elektrine.Social.Message.decrypt_messages()
    |> Enum.map(&post_entry/1)
  end

  defp list_likes(user_id, offset, limit, query) do
    search_term = search_pattern(query)

    from(m in Elektrine.Social.Message,
      where:
        m.sender_id == ^user_id and m.post_type in ["post", "gallery", "discussion"] and
          is_nil(m.deleted_at) and m.is_draft == false and m.like_count > 0,
      where:
        ^is_nil(search_term) or ilike(fragment("coalesce(?, '')", m.title), ^search_term) or
          ilike(fragment("coalesce(?, '')", m.content), ^search_term),
      order_by: [desc: m.like_count, desc: m.inserted_at],
      offset: ^offset,
      limit: ^limit,
      preload: [:conversation]
    )
    |> Repo.all()
    |> Elektrine.Social.Message.decrypt_messages()
    |> Enum.map(&like_entry/1)
  end

  defp list_relationships(user_id, direction, offset, limit, query) do
    search_term = search_pattern(query)

    local_query =
      case direction do
        :followers ->
          from(f in Profiles.Follow,
            join: u in assoc(f, :follower),
            where: f.followed_id == ^user_id and not is_nil(f.follower_id) and f.pending == false,
            select: %{
              type: "local",
              name: fragment("coalesce(?, ?)", u.display_name, u.username),
              handle: fragment("coalesce(?, ?)", u.handle, u.username),
              domain: type(^nil, :string),
              href: fragment("concat('/', coalesce(?, ?))", u.handle, u.username),
              followed_at: f.inserted_at,
              user_id: u.id,
              remote_actor_id: type(^nil, :integer)
            }
          )

        :following ->
          from(f in Profiles.Follow,
            join: u in assoc(f, :followed),
            where: f.follower_id == ^user_id and not is_nil(f.followed_id) and f.pending == false,
            select: %{
              type: "local",
              name: fragment("coalesce(?, ?)", u.display_name, u.username),
              handle: fragment("coalesce(?, ?)", u.handle, u.username),
              domain: type(^nil, :string),
              href: fragment("concat('/', coalesce(?, ?))", u.handle, u.username),
              followed_at: f.inserted_at,
              user_id: u.id,
              remote_actor_id: type(^nil, :integer)
            }
          )
      end

    remote_query =
      case direction do
        :followers ->
          from(f in Profiles.Follow,
            join: a in assoc(f, :remote_actor),
            where:
              f.followed_id == ^user_id and not is_nil(f.remote_actor_id) and f.pending == false,
            select: %{
              type: "remote",
              name: fragment("coalesce(?, ?)", a.display_name, a.username),
              handle: a.username,
              domain: a.domain,
              href: fragment("concat('/remote/', ?, '@', ?)", a.username, a.domain),
              followed_at: f.inserted_at,
              user_id: type(^nil, :integer),
              remote_actor_id: a.id
            }
          )

        :following ->
          from(f in Profiles.Follow,
            join: a in assoc(f, :remote_actor),
            where:
              f.follower_id == ^user_id and not is_nil(f.remote_actor_id) and
                (f.pending == false or a.manually_approves_followers == false),
            select: %{
              type: "remote",
              name: fragment("coalesce(?, ?)", a.display_name, a.username),
              handle: a.username,
              domain: a.domain,
              href: fragment("concat('/remote/', ?, '@', ?)", a.username, a.domain),
              followed_at: f.inserted_at,
              user_id: type(^nil, :integer),
              remote_actor_id: a.id
            }
          )
      end

    combined_query = union_all(local_query, ^remote_query)

    from(r in subquery(combined_query),
      where:
        ^is_nil(search_term) or ilike(fragment("coalesce(?, '')", r.name), ^search_term) or
          ilike(fragment("coalesce(?, '')", r.handle), ^search_term) or
          ilike(fragment("coalesce(?, '')", r.domain), ^search_term),
      order_by: [desc: r.followed_at],
      offset: ^offset,
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.map(&relationship_entry(&1, direction))
  end

  defp post_entry(post) do
    image_preview_url =
      post.media_urls
      |> List.wrap()
      |> PostUtilities.filter_image_urls()
      |> List.first()

    media_count = length(List.wrap(post.media_urls))

    %{
      kind: :post,
      id: post.id,
      href: Elektrine.Paths.post_path(post.id),
      title: social_post_title(post),
      preview:
        PostUtilities.render_content_preview(
          post.content || "",
          PostUtilities.get_instance_domain(post),
          160
        ),
      meta: post_type_label(post.post_type),
      at: post.inserted_at,
      count_label: nil,
      count_value: nil,
      media_count: media_count,
      media_label: media_label(post, media_count),
      preview_image_url: image_preview_url,
      remote_actor_id: nil,
      user_id: nil
    }
  end

  defp like_entry(post) do
    post
    |> post_entry()
    |> Map.put(:meta, "#{post_type_label(post.post_type)} post")
    |> Map.put(:count_label, "likes")
    |> Map.put(:count_value, post.like_count || 0)
  end

  defp relationship_entry(entry, direction) do
    handle =
      case entry.type do
        "remote" -> "@#{entry.handle}@#{entry.domain}"
        _ -> "@#{entry.handle}"
      end

    %{
      kind: :relationship,
      id: entry.user_id || entry.remote_actor_id,
      href: entry.href,
      title: entry.name,
      preview: ElektrineWeb.HtmlHelpers.escape_html(handle),
      meta: if(direction == :followers, do: "followed you", else: "you follow"),
      at: entry.followed_at,
      count_label: nil,
      count_value: nil,
      media_count: 0,
      media_label: nil,
      preview_image_url: nil,
      remote_actor_id: entry.remote_actor_id,
      user_id: entry.user_id
    }
  end

  defp post_type_label("post"), do: "Timeline"
  defp post_type_label("gallery"), do: "Gallery"
  defp post_type_label("discussion"), do: "Discuss"
  defp post_type_label(type), do: String.capitalize(type)

  defp search_pattern(query) do
    case String.trim(query || "") do
      "" -> nil
      trimmed -> "%#{trimmed}%"
    end
  end

  defp media_label(_post, 0), do: nil

  defp media_label(post, count) when post.post_type == "gallery",
    do: pluralize_media(count)

  defp media_label(_post, count), do: pluralize_media(count)

  defp pluralize_media(1), do: "1 media item"
  defp pluralize_media(count), do: "#{count} media items"

  defp social_post_title(post) do
    post
    |> then(fn post ->
      ElektrineWeb.HtmlHelpers.plain_text_content(post.title || post.content)
    end)
    |> trim_or("New social post")
    |> truncate_text(72)
  end

  defp trim_or(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp trim_or(_value, fallback), do: fallback

  defp truncate_text(text, max_length) when is_binary(text) and max_length > 1 do
    if String.length(text) > max_length do
      text
      |> String.slice(0, max_length - 1)
      |> String.trim()
      |> Kernel.<>("...")
    else
      text
    end
  end

  defp truncate_text(_text, _max_length), do: ""
end
