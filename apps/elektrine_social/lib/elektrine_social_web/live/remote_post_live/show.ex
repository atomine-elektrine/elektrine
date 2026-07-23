defmodule ElektrineSocialWeb.RemotePostLive.Show do
  use ElektrineSocialWeb, :live_view

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.Messaging
  alias Elektrine.Paths
  alias Elektrine.Profiles
  alias Elektrine.Security.SafeExternalURL
  alias Elektrine.Social
  alias ElektrineSocialWeb.Components.Social.PostUtilities

  @cached_reply_poll_interval_ms 1_500
  @cached_reply_poll_max_attempts 8

  alias ElektrineSocialWeb.RemotePostLive.{
    AccessPolicy,
    AncestorContextComponents,
    CachedPostFields,
    Counts,
    DiscussionSource,
    DisplayCounts,
    Interactions,
    Navigation,
    Polls,
    QuickReplyComponents,
    SubmittedLinks,
    SurfaceHelpers,
    ThreadedCommentComponents,
    Threading
  }

  alias ElektrineWeb.Live.PostInteractions

  import ElektrineSocialWeb.Components.Platform.ENav

  import ElektrineSocialWeb.RemotePostLive.DetailComponents,
    only: [empty_comments_state: 1, standard_timeline_detail_post: 1]

  import ElektrineSocialWeb.RemotePostLive.DetailState,
    only: [
      detail_message_interaction: 2,
      detail_message_reactions: 2,
      detail_message_saved?: 2,
      detail_post_keys: 2,
      load_detail_post_interactions: 3,
      load_local_detail_user_state: 4,
      main_post_interaction_state: 3,
      merge_remote_post_reactions: 3,
      misskey_emoji_reactions: 1,
      reset_main_post_vote_delta: 3
    ]

  import ElektrineSocialWeb.RemotePostLive.QuickReplyComponents,
    only: [quick_reply_recent_replies_preview: 1]

  import CachedPostFields,
    only: [
      cached_message_attachments: 1,
      cached_remote_status_fields: 1,
      map_get_value: 2,
      maybe_preserve_cached_post_fields: 2,
      message_attachment_url: 2,
      normalize_attachment_list: 1
    ]

  import ElektrineWeb.HtmlHelpers
  import Elektrine.Components.Loaders.Skeleton

  @submitted_preview_poll_attempts 10
  @submitted_preview_poll_interval_ms 1_000

  defdelegate render_threaded_comments(assigns, comments), to: ThreadedCommentComponents
  defdelegate ancestor_context_stack(assigns), to: AncestorContextComponents
  defdelegate message_submitted_link(message), to: SubmittedLinks
  defdelegate detect_submitted_url(post, local_message, remote_actor_domain), to: SubmittedLinks
  defdelegate extract_youtube_id(url), to: SubmittedLinks
  defdelegate submitted_url_host(url), to: SubmittedLinks

  defp thread_hydration_state(
         reported_reply_count,
         loaded_reply_count,
         replies_loading,
         reply_sync_checked
       )
       when is_integer(reported_reply_count) and is_integer(loaded_reply_count) do
    cond do
      reported_reply_count <= 0 and loaded_reply_count <= 0 -> "idle"
      replies_loading and loaded_reply_count <= 0 -> "syncing"
      replies_loading and loaded_reply_count < reported_reply_count -> "partial"
      loaded_reply_count > 0 and loaded_reply_count < reported_reply_count -> "partial"
      reply_sync_checked and loaded_reply_count <= 0 and reported_reply_count > 0 -> "failed"
      loaded_reply_count >= reported_reply_count and loaded_reply_count > 0 -> "complete"
      true -> "idle"
    end
  end

  defp thread_hydration_state(_, _, _, _), do: "idle"

  def standard_timeline_detail_reply_box(assigns),
    do: QuickReplyComponents.standard_timeline_detail_reply_box(assigns)

  defp use_standard_timeline_detail?(message, is_community_post) do
    is_map(message) &&
      !Map.get(message, :federated, false) &&
      !is_community_post &&
      (loaded_assoc?(Map.get(message, :sender)) || loaded_assoc?(Map.get(message, :remote_actor)))
  end

  defp loaded_assoc?(%Ecto.Association.NotLoaded{}), do: false
  defp loaded_assoc?(nil), do: false
  defp loaded_assoc?(_), do: true

  @impl true
  def mount(%{"url" => url}, _session, socket) when is_binary(url) do
    mount_post_ref(url, socket)
  end

  def mount(%{"post_id" => post_id}, _session, socket) do
    # post_id could be a URL-encoded ActivityPub ID or a numeric local ID
    decoded_post_id = URI.decode_www_form(post_id)

    mount_post_ref(decoded_post_id, socket)
  end

  @impl true
  def handle_params(%{"url" => url}, uri, socket) do
    if remote_activitypub_ref?(url),
      do: {:noreply, socket},
      else: handle_canonical_params(url, uri, socket)
  end

  def handle_params(%{"post_id" => post_id}, uri, socket) do
    decoded_post_id = URI.decode_www_form(post_id)

    if remote_activitypub_ref?(decoded_post_id),
      do: {:noreply, socket},
      else: handle_canonical_params(decoded_post_id, uri, socket)
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp handle_canonical_params(ref, uri, socket) do
    current_path = Navigation.current_post_path_from_uri(uri)
    canonical_path = Navigation.canonical_remote_post_path(ref)

    if is_binary(canonical_path) and canonical_path != current_path do
      {:noreply, push_patch(socket, to: canonical_path, replace: true)}
    else
      {:noreply, socket}
    end
  end

  defp remote_activitypub_ref?(ref) when is_binary(ref), do: String.contains?(ref, "://")
  defp remote_activitypub_ref?(_), do: false

  defp mount_post_ref(decoded_post_id, socket) do
    # Check if this is a numeric local post ID
    local_post_id =
      case Navigation.parse_local_message_id(decoded_post_id) do
        {:ok, parsed} -> parsed
        :error -> nil
      end

    is_local_post = is_integer(local_post_id)

    # Keep layout stable for community-style posts from the first render.
    initial_discussion_source =
      DiscussionSource.remote_discussion_source(decoded_post_id, nil, nil)

    is_community_post = !is_local_post && initial_discussion_source == :lemmy

    # Initialize with loading state
    socket =
      socket
      |> assign(:page_title, "Loading post...")
      |> assign(:loading, true)
      |> assign(:load_error, nil)
      |> assign(:post_id, decoded_post_id)
      |> assign(:is_local_post, is_local_post)
      |> assign(:is_community_post, is_community_post)
      |> assign(:trust_topic_tracked, false)
      |> assign(:local_message, nil)
      |> assign(:post, nil)
      |> assign(:pending_remote_poll_vote, nil)
      |> assign(:remote_actor, nil)
      |> assign(:community_actor, nil)
      |> assign(:community_stats, %{members: 0, posts: 0})
      |> assign(:community_lookup_complete, false)
      |> assign(:is_following_community, false)
      |> assign(:is_pending_community, false)
      |> assign(:is_following_author, false)
      |> assign(:is_pending_author, false)
      |> assign(:user_follows, %{})
      |> assign(:pending_follows, %{})
      |> assign(:remote_follow_overrides, %{})
      |> assign(:replies, [])
      |> assign(:threaded_replies, [])
      |> assign(:thread_reply_actors, %{})
      |> assign(:replies_loading, false)
      |> assign(:replies_loaded, false)
      |> assign(:awaiting_initial_comment_counts, false)
      |> assign(:pending_initial_comment_reveal, false)
      |> assign(:reply_sync_checked, false)
      |> assign(:comment_sort, "hot")
      |> assign(:post_interactions, %{})
      |> assign(:user_saves, %{})
      |> assign(:lemmy_counts, nil)
      |> assign(:lemmy_comment_counts, %{})
      |> assign(:mastodon_counts, nil)
      |> assign(:show_reply_form, false)
      |> assign(:reply_content, "")
      |> assign(:quick_reply_recent_replies, [])
      |> assign(:replying_to_comment_id, nil)
      |> assign(:comment_reply_content, "")
      |> assign(:show_image_modal, false)
      |> assign(:modal_image_url, nil)
      |> assign(:modal_images, [])
      |> assign(:modal_image_index, 0)
      |> assign(:modal_post, nil)
      |> assign(:post_reactions, %{})
      |> assign(:in_reply_to, nil)
      |> assign(:reply_parent, nil)
      |> assign(:reply_parent_actor, nil)
      |> assign(:reply_ancestors, [])
      |> assign(:meta_robots, "noindex, nofollow")
      |> assign(:meta_description, nil)
      |> assign(:og_image, nil)
      |> assign(:submitted_link_preview, nil)
      |> assign(:remote_post_load_ref, nil)
      |> assign(:platform_counts_load_ref, nil)
      |> assign(:platform_counts_refresh_ref, nil)
      |> assign(:reply_counts_load_ref, nil)
      |> assign(:reply_counts_refresh_ref, nil)
      |> assign(:community_lookup_ref, nil)
      |> assign(
        :current_url,
        ElektrineWeb.Endpoint.url() <>
          (Navigation.canonical_remote_post_path(decoded_post_id) || "")
      )

    # For initial render (not connected), do a quick synchronous fetch for SEO/link previews
    # This ensures meta tags are present in the initial HTML for crawlers
    socket =
      if connected?(socket) do
        socket
      else
        fetch_post_for_meta_tags(socket, local_post_id || decoded_post_id, is_local_post)
      end

    # Defer full HTTP fetching to handle_info for interactive use
    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "timeline:public")

        cond do
          is_local_post ->
            {:noreply, socket} =
              handle_info({:load_local_post, local_post_id}, socket)

            socket

          Elektrine.RuntimeEnv.environment() == :test ->
            load_cached_remote_post_socket(socket, decoded_post_id) ||
              (send(self(), {:load_remote_post, decoded_post_id}) && socket)

          true ->
            send(self(), {:load_remote_post, decoded_post_id})
            socket
        end
      else
        socket
      end

    {:ok, socket}
  end

  # Build an ActivityPub-like post object from a local message
  defp build_post_object_from_message(msg) do
    poll_fields = Polls.build_poll_fields_from_message(msg)
    reply_count = Counts.cached_reply_count(msg)
    submitted_link = SubmittedLinks.message_submitted_link(msg)
    post_url = submitted_link || msg.activitypub_url || msg.activitypub_id
    metadata = msg.media_metadata || %{}
    in_reply_to = message_in_reply_to(msg)
    community_uri = DiscussionSource.community_uri_from_local_message(msg)

    attachments = cached_message_attachments(msg)

    %{
      "id" => msg.activitypub_id,
      "type" =>
        metadata["type"] ||
          if(DiscussionSource.community_post_url?(msg.activitypub_id || post_url || ""),
            do: "Page",
            else: "Note"
          ),
      "url" => post_url,
      "content" => msg.content,
      "published" => NaiveDateTime.to_iso8601(msg.inserted_at) <> "Z",
      "attributedTo" => msg.remote_actor && msg.remote_actor.uri,
      "inReplyTo" => in_reply_to,
      "indexable" => AccessPolicy.cached_message_indexable?(msg),
      "audience" => community_uri,
      "to" => build_cached_post_audience(community_uri),
      "inReplyToAuthor" => metadata["inReplyToAuthor"],
      "inReplyToContent" => metadata["inReplyToContent"],
      "inReplyToTitle" => metadata["inReplyToTitle"],
      "attachment" => attachments,
      "name" => msg.title,
      "likes" => %{"totalItems" => msg.like_count || 0},
      "shares" => %{"totalItems" => msg.share_count || 0},
      "repliesCount" => reply_count,
      "replies" => %{"totalItems" => reply_count},
      "like_count" => msg.like_count || 0,
      "reply_count" => reply_count,
      "share_count" => msg.share_count || 0,
      "quotes_count" => msg.quote_count || 0,
      "upvotes" => msg.upvotes || 0,
      "downvotes" => msg.downvotes || 0,
      "score" => max(msg.score || 0, msg.like_count || 0),
      "_cached" => true,
      "_local_message" => msg
    }
    |> Map.merge(cached_remote_status_fields(metadata))
    |> Map.merge(poll_fields)
  end

  defp maybe_enrich_cached_federated_post(post_object, msg)
       when is_map(post_object) and is_map(msg) do
    needs_origin_body = !Elektrine.Strings.present?(map_get_value(post_object, "content"))
    cached_attachments = normalize_attachment_list(map_get_value(post_object, "attachment"))
    needs_origin_media = cached_attachments == []

    remote_ref =
      [msg.activitypub_id, msg.activitypub_url]
      |> Enum.find(&(is_binary(&1) && String.trim(&1) != ""))

    if (needs_origin_media || (needs_origin_body && cached_attachments == [])) &&
         is_binary(remote_ref) do
      case strict_fetch_remote_object(remote_ref) do
        {:ok, remote_post} when is_map(remote_post) ->
          maybe_preserve_cached_post_fields(post_object, remote_post)

        _ ->
          post_object
      end
    else
      post_object
    end
  end

  defp maybe_enrich_cached_federated_post(post_object, _), do: post_object

  defp build_cached_post_audience(nil), do: nil

  defp build_cached_post_audience(community_uri) when is_binary(community_uri) do
    [community_uri, "https://www.w3.org/ns/activitystreams#Public"]
  end

  defp effective_link_preview(local_message, submitted_link_preview, submitted_url) do
    cond do
      match?(%Elektrine.Social.LinkPreview{status: "success"}, submitted_link_preview) and
          preview_matches_submitted_url?(submitted_link_preview, submitted_url) ->
        submitted_link_preview

      match?(%{link_preview: %Elektrine.Social.LinkPreview{status: "success"}}, local_message) and
          preview_matches_submitted_url?(local_message.link_preview, submitted_url) ->
        local_message.link_preview

      true ->
        nil
    end
  end

  defp preview_matches_submitted_url?(%Elektrine.Social.LinkPreview{url: url}, submitted_url)
       when is_binary(url) and is_binary(submitted_url) do
    SubmittedLinks.normalize_http_url(url) == SubmittedLinks.normalize_http_url(submitted_url)
  end

  defp preview_matches_submitted_url?(_, nil), do: false
  defp preview_matches_submitted_url?(_, _), do: false

  defp preview_title_duplicates_post?(preview_title, post_title)
       when is_binary(preview_title) and is_binary(post_title) do
    normalize_preview_text(preview_title) == normalize_preview_text(post_title)
  end

  defp preview_title_duplicates_post?(_, _), do: false

  defp normalize_preview_text(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp ensure_submitted_link_preview(socket, post_object, local_message, remote_actor_domain)
       when is_map(post_object) do
    case SubmittedLinks.detect_submitted_url(post_object, local_message, remote_actor_domain) do
      url when is_binary(url) ->
        if preview_matches_submitted_url?(local_message && local_message.link_preview, url) do
          assign(socket, :submitted_link_preview, nil)
        else
          case Elektrine.Repo.get_by(Elektrine.Social.LinkPreview, url: url) do
            %Elektrine.Social.LinkPreview{status: "success"} = preview ->
              assign(socket, :submitted_link_preview, preview)

            _ ->
              maybe_enqueue_submitted_link_preview(url, local_message)
              maybe_schedule_submitted_preview_poll(socket, url)
              assign(socket, :submitted_link_preview, nil)
          end
        end

      _ ->
        assign(socket, :submitted_link_preview, nil)
    end
  end

  defp ensure_submitted_link_preview(socket, _, _, _),
    do: assign(socket, :submitted_link_preview, nil)

  defp maybe_enqueue_submitted_link_preview(url, local_message) when is_binary(url) do
    message_id =
      case local_message do
        %{id: id} when is_integer(id) -> id
        _ -> nil
      end

    _ = Social.FetchLinkPreviewWorker.enqueue(url, message_id)
    :ok
  rescue
    _ -> :ok
  end

  defp maybe_schedule_submitted_preview_poll(socket, url) when is_binary(url) do
    if connected?(socket) do
      Process.send_after(
        self(),
        {:poll_submitted_link_preview, url, @submitted_preview_poll_attempts},
        @submitted_preview_poll_interval_ms
      )
    end

    :ok
  end

  defp current_submitted_url(%Phoenix.LiveView.Socket{} = socket) do
    SubmittedLinks.detect_submitted_url(
      socket.assigns[:post],
      socket.assigns[:local_message],
      socket.assigns[:remote_actor] && socket.assigns.remote_actor.domain
    )
  end

  defp current_submitted_url(assigns) when is_map(assigns) do
    SubmittedLinks.detect_submitted_url(
      Map.get(assigns, :post),
      Map.get(assigns, :local_message),
      case Map.get(assigns, :remote_actor) do
        %{domain: domain} -> domain
        _ -> nil
      end
    )
  end

  defp maybe_repair_local_message_submitted_link(local_message, post_object, remote_actor_domain)
       when is_map(local_message) and is_map(post_object) do
    local_message = resolve_local_message_for_post(local_message, post_object)

    case {SubmittedLinks.message_submitted_link(local_message),
          SubmittedLinks.detect_submitted_url(post_object, local_message, remote_actor_domain)} do
      {nil, submitted_url} when is_binary(submitted_url) ->
        import Ecto.Query

        repaired_metadata =
          Map.put(local_message.media_metadata || %{}, "external_link", submitted_url)

        Elektrine.Repo.update_all(
          from(m in Elektrine.Social.Message, where: m.id == ^local_message.id),
          set: [
            primary_url: submitted_url,
            media_metadata: repaired_metadata,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )

        latest_local_message_for_post(
          local_message.activitypub_id || local_message.activitypub_url
        ) ||
          %{local_message | primary_url: submitted_url, media_metadata: repaired_metadata}

      _ ->
        local_message
    end
  rescue
    error in Postgrex.Error ->
      if unique_activitypub_violation?(error) do
        resolve_local_message_for_post(local_message, post_object) || local_message
      else
        reraise error, __STACKTRACE__
      end
  end

  defp maybe_repair_local_message_submitted_link(local_message, _, _), do: local_message

  defp maybe_enqueue_submitted_link_repair(%{id: message_id} = local_message)
       when is_integer(message_id) do
    if is_nil(SubmittedLinks.message_submitted_link(local_message)) do
      _ = Elektrine.ActivityPub.SubmittedLinkRepairWorker.enqueue_single(message_id)
    end

    local_message
  end

  defp maybe_enqueue_submitted_link_repair(local_message), do: local_message

  defp preview_display_text(text) when is_binary(text) do
    decode_preview_entities(text, 3)
  end

  defp preview_display_text(_), do: nil

  defp decode_preview_entities(text, remaining) when is_binary(text) and remaining > 0 do
    decoded = HtmlEntities.decode(text)
    if decoded == text, do: decoded, else: decode_preview_entities(decoded, remaining - 1)
  end

  defp decode_preview_entities(text, _), do: text

  defp quote_message_path(%{activitypub_id: activitypub_id})
       when is_binary(activitypub_id) and activitypub_id != "" do
    Navigation.remote_detail_post_path(activitypub_id)
  end

  defp quote_message_path(%{id: id}) when is_integer(id),
    do: Navigation.remote_detail_post_path(id)

  defp quote_message_path(%{id: id}) when is_binary(id) and id != "" do
    Navigation.remote_detail_post_path(id)
  end

  defp quote_message_path(_), do: nil

  defp assign_local_first_post(socket, local_message, fallback_post_object)
       when is_map(local_message) do
    local_message
    |> build_post_object_from_message()
    |> Polls.merge_local_poll_data(local_message)
    |> maybe_preserve_cached_post_fields(fallback_post_object || %{})
    |> then(fn post ->
      robots =
        if local_message.federated,
          do: AccessPolicy.robots_for_remote_post(post),
          else: AccessPolicy.robots_for_local_post(local_message)

      socket
      |> assign(:post, post)
      |> assign(:meta_robots, robots)
    end)
  end

  defp assign_local_first_post(socket, _, _), do: socket

  defp preload_cached_message_associations(message) do
    preloads =
      Elektrine.Social.Messages.timeline_post_preloads()
      |> Enum.map(fn
        {:conversation, _} -> {:conversation, [:remote_group_actor]}
        other -> other
      end)

    Elektrine.Repo.preload(message, preloads)
  end

  defp fetch_local_message_for_detail(message_id) when is_binary(message_id) do
    case Integer.parse(String.trim(message_id)) do
      {parsed, ""} -> fetch_local_message_for_detail(parsed)
      _ -> nil
    end
  end

  defp fetch_local_message_for_detail(message_id)
       when is_integer(message_id) and message_id > 0 do
    import Ecto.Query

    case Elektrine.Social.Message
         |> where([m], m.id == ^message_id)
         |> Elektrine.Repo.one() do
      nil ->
        nil

      message ->
        preloads =
          if message.federated && is_binary(message.activitypub_id) do
            Elektrine.Social.Messages.timeline_post_preloads() ++
              [
                replies: [
                  sender: [:profile],
                  remote_actor: [],
                  reply_to: [sender: [:profile], remote_actor: []]
                ]
              ]
          else
            Elektrine.Social.Messages.timeline_post_preloads() ++
              [
                replies: [
                  sender: [:profile],
                  remote_actor: [],
                  reply_to: [sender: [:profile], remote_actor: []]
                ]
              ]
          end

        Elektrine.Repo.preload(message, preloads)
    end
  end

  defp fetch_local_message_for_detail(_), do: nil

  defp message_in_reply_to(message) when is_map(message) do
    metadata = local_message_metadata(message)

    [metadata["inReplyTo"], metadata["in_reply_to"], message_reply_parent(message)]
    |> Enum.find_value(&normalize_in_reply_to_ref/1)
  end

  defp local_message_metadata(%{media_metadata: metadata}) when is_map(metadata), do: metadata
  defp local_message_metadata(_), do: %{}

  defp message_reply_parent(%{reply_to: reply_to}) when is_map(reply_to) do
    activitypub_ref_for_message(reply_to)
  end

  defp message_reply_parent(%{reply_to_id: reply_to_id}) when is_integer(reply_to_id) do
    reply_to_id
    |> Messaging.get_message()
    |> activitypub_ref_for_message()
  end

  defp message_reply_parent(_), do: nil

  defp activitypub_ref_for_message(%{activitypub_id: id}) when is_binary(id) and id != "", do: id

  defp activitypub_ref_for_message(%{activitypub_url: url}) when is_binary(url) and url != "",
    do: url

  defp activitypub_ref_for_message(%{id: id}) when is_integer(id) do
    "#{ElektrineWeb.Endpoint.url()}/posts/#{id}"
  end

  defp activitypub_ref_for_message(_), do: nil

  defp maybe_assign_cached_lemmy_counts(socket, message) when is_map(message) do
    if is_nil(socket.assigns[:lemmy_counts]) && PostUtilities.community_post?(message) do
      assign(socket, :lemmy_counts, %{
        upvotes: max(Map.get(message, :upvotes) || 0, 0),
        downvotes: max(Map.get(message, :downvotes) || 0, 0),
        score: max(Map.get(message, :score) || 0, Map.get(message, :like_count) || 0),
        comments: max(Counts.cached_reply_count(message), 0)
      })
    else
      socket
    end
  end

  defp maybe_assign_cached_lemmy_counts(socket, _message), do: socket

  defp normalize_in_reply_to_ref(%{"id" => id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{"href" => href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref(%{id: id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{href: href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref([first | _]), do: normalize_in_reply_to_ref(first)

  defp normalize_in_reply_to_ref(ref) when is_binary(ref) do
    ref
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_in_reply_to_ref(_), do: nil

  defp extract_post_in_reply_to(post_object, local_message) do
    local_metadata = local_message_metadata(local_message)

    [
      map_get_value(post_object, "inReplyTo"),
      map_get_value(post_object, "in_reply_to"),
      local_metadata["inReplyTo"],
      local_metadata["in_reply_to"],
      message_reply_parent(local_message)
    ]
    |> Enum.find_value(&normalize_in_reply_to_ref/1)
  end

  defp assign_reply_parent_fallback(socket, post_object, local_message) do
    in_reply_to = extract_post_in_reply_to(post_object, local_message)

    local_ancestors = resolve_local_reply_ancestor_chain(in_reply_to)

    {reply_parent, reply_parent_actor, reply_ancestors} =
      case local_ancestors do
        [first | _] ->
          {first.post, first.actor, local_ancestors}

        [] ->
          fallback_parent = build_reply_parent_fallback(post_object, local_message, in_reply_to)
          fallback_entry = build_reply_ancestor_entry(fallback_parent, nil, in_reply_to)
          {fallback_parent, nil, if(fallback_entry, do: [fallback_entry], else: [])}
      end

    socket
    |> assign(:in_reply_to, in_reply_to)
    |> assign(:reply_parent, reply_parent)
    |> assign(:reply_parent_actor, reply_parent_actor)
    |> assign(:reply_ancestors, reply_ancestors)
  end

  defp build_reply_parent_fallback(post_object, local_message, in_reply_to) do
    metadata = local_message_metadata(local_message)

    content =
      map_get_value(post_object, "inReplyToContent") ||
        metadata["inReplyToContent"] ||
        metadata["in_reply_to_content"]

    title =
      map_get_value(post_object, "inReplyToTitle") ||
        metadata["inReplyToTitle"] ||
        metadata["in_reply_to_title"]

    author =
      map_get_value(post_object, "inReplyToAuthor") ||
        metadata["inReplyToAuthor"] ||
        metadata["in_reply_to_author"]

    if is_binary(in_reply_to) || is_binary(content) || is_binary(title) || is_binary(author) do
      %{
        "id" => in_reply_to,
        "url" => in_reply_to,
        "type" => "Note",
        "name" => title,
        "content" => content,
        "_fallback_author" => normalize_reply_parent_author(author)
      }
    else
      nil
    end
  end

  defp normalize_reply_parent_author(%{"name" => name}), do: normalize_reply_parent_author(name)
  defp normalize_reply_parent_author(%{"url" => url}), do: normalize_reply_parent_author(url)
  defp normalize_reply_parent_author(%{name: name}), do: normalize_reply_parent_author(name)
  defp normalize_reply_parent_author(%{url: url}), do: normalize_reply_parent_author(url)

  defp normalize_reply_parent_author(author) when is_binary(author) do
    author
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_reply_parent_author(_), do: nil

  defp local_reply_parent_from_ref(in_reply_to) when is_binary(in_reply_to) do
    case local_message_by_activitypub_ref(in_reply_to) do
      %{} = parent_message ->
        parent_message = preload_cached_message_associations(parent_message)
        {:ok, build_reply_parent_from_message(parent_message), parent_message.remote_actor}

      _ ->
        :error
    end
  rescue
    error in Postgrex.Error ->
      if postgres_error_code(error) == :index_corrupted do
        Logger.error(
          "Postgres index corruption while resolving reply parent: #{Exception.message(error)}"
        )

        :error
      else
        reraise error, __STACKTRACE__
      end
  end

  defp build_reply_parent_from_message(message) do
    base_url = ElektrineWeb.Endpoint.url()
    metadata = local_message_metadata(message)

    attributed_to =
      cond do
        message.remote_actor && is_binary(message.remote_actor.uri) ->
          message.remote_actor.uri

        message.sender && is_binary(message.sender.username) ->
          "#{base_url}/users/#{message.sender.username}"

        true ->
          nil
      end

    %{
      "id" => activitypub_ref_for_message(message),
      "url" =>
        message.activitypub_url || message.activitypub_id || activitypub_ref_for_message(message),
      "type" =>
        metadata["type"] ||
          if(
            DiscussionSource.community_post_url?(
              message.activitypub_id || message.activitypub_url || ""
            ),
            do: "Page",
            else: "Note"
          ),
      "name" => message.title,
      "content" => message.content || metadata["inReplyToContent"],
      "published" => NaiveDateTime.to_iso8601(message.inserted_at) <> "Z",
      "attributedTo" => attributed_to,
      "inReplyTo" => message_in_reply_to(message),
      "likes" => %{"totalItems" => message.like_count || 0},
      "shares" => %{"totalItems" => message.share_count || 0},
      "repliesCount" => message.reply_count || 0,
      "replies" => %{"totalItems" => message.reply_count || 0},
      "_local_message_id" => message.id,
      "_local_like_count" => SurfaceHelpers.local_vote_display_count(message),
      "_local_share_count" => message.share_count || 0,
      "_local_reply_count" => message.reply_count || 0,
      "_local_user" => message.sender
    }
  end

  defp build_reply_ancestor_entry(parent_post, parent_actor, in_reply_to)
       when is_map(parent_post) do
    %{
      post: parent_post,
      actor: parent_actor,
      in_reply_to: in_reply_to
    }
  end

  defp build_reply_ancestor_entry(_, _, _), do: nil

  defp resolve_local_reply_ancestor_chain(in_reply_to, max_depth \\ 8)

  defp resolve_local_reply_ancestor_chain(in_reply_to, max_depth)
       when is_binary(in_reply_to) and max_depth > 0 do
    do_resolve_local_reply_ancestor_chain(
      normalize_in_reply_to_ref(in_reply_to),
      [],
      MapSet.new(),
      max_depth
    )
  end

  defp resolve_local_reply_ancestor_chain(_, _), do: []

  defp do_resolve_local_reply_ancestor_chain(nil, acc, _seen, _depth), do: Enum.reverse(acc)

  defp do_resolve_local_reply_ancestor_chain(_, acc, _seen, depth) when depth <= 0,
    do: Enum.reverse(acc)

  defp do_resolve_local_reply_ancestor_chain(ref, acc, seen, depth) do
    if MapSet.member?(seen, ref) do
      Enum.reverse(acc)
    else
      case local_message_by_activitypub_ref(ref) do
        %{} = parent_message ->
          parent_message = preload_cached_message_associations(parent_message)
          parent_post = build_reply_parent_from_message(parent_message)
          entry = build_reply_ancestor_entry(parent_post, parent_message.remote_actor, ref)
          next_ref = message_in_reply_to(parent_message)
          next_seen = MapSet.put(seen, ref)

          do_resolve_local_reply_ancestor_chain(
            normalize_in_reply_to_ref(next_ref),
            if(entry, do: [entry | acc], else: acc),
            next_seen,
            depth - 1
          )

        _ ->
          Enum.reverse(acc)
      end
    end
  end

  defp resolve_reply_parent(in_reply_to) when is_binary(in_reply_to) do
    case local_reply_parent_from_ref(in_reply_to) do
      {:ok, parent_post, parent_actor} ->
        {:ok, parent_post, parent_actor}

      :error ->
        case strict_fetch_remote_object(in_reply_to) do
          {:ok, parent_object} ->
            parent_post = normalize_reply_parent_post(parent_object, in_reply_to)

            case parent_post do
              %{} ->
                {:ok, parent_post, maybe_fetch_reply_parent_actor(parent_post)}

              _ ->
                {:error, :invalid_parent}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp resolve_reply_parent(_), do: {:error, :missing_parent}

  defp resolve_reply_ancestor_chain(in_reply_to, max_depth \\ 8)

  defp resolve_reply_ancestor_chain(in_reply_to, max_depth)
       when is_binary(in_reply_to) and max_depth > 0 do
    do_resolve_reply_ancestor_chain(
      normalize_in_reply_to_ref(in_reply_to),
      [],
      MapSet.new(),
      max_depth
    )
  end

  defp resolve_reply_ancestor_chain(_, _), do: {:error, :missing_parent}

  defp do_resolve_reply_ancestor_chain(nil, [], _seen, _depth), do: {:error, :missing_parent}
  defp do_resolve_reply_ancestor_chain(nil, acc, _seen, _depth), do: {:ok, Enum.reverse(acc)}

  defp do_resolve_reply_ancestor_chain(_, acc, _seen, depth) when depth <= 0,
    do: {:ok, Enum.reverse(acc)}

  defp do_resolve_reply_ancestor_chain(ref, acc, seen, depth) do
    if MapSet.member?(seen, ref) do
      {:ok, Enum.reverse(acc)}
    else
      case resolve_reply_parent(ref) do
        {:ok, parent_post, parent_actor} ->
          entry = build_reply_ancestor_entry(parent_post, parent_actor, ref)
          next_ref = parent_post_in_reply_to_ref(parent_post)
          next_seen = MapSet.put(seen, ref)

          do_resolve_reply_ancestor_chain(
            normalize_in_reply_to_ref(next_ref),
            if(entry, do: [entry | acc], else: acc),
            next_seen,
            depth - 1
          )

        {:error, reason} ->
          if acc == [], do: {:error, reason}, else: {:ok, Enum.reverse(acc)}
      end
    end
  end

  defp normalize_reply_parent_post(
         %{"type" => "Create", "object" => %{} = inner_object},
         fallback_id
       ) do
    normalize_reply_parent_post(inner_object, fallback_id)
  end

  defp normalize_reply_parent_post(%{} = parent_object, fallback_id) do
    id = map_get_value(parent_object, "id") || fallback_id

    %{
      "id" => id,
      "url" => map_get_value(parent_object, "url") || id,
      "type" => map_get_value(parent_object, "type") || "Note",
      "name" => map_get_value(parent_object, "name"),
      "content" =>
        map_get_value(parent_object, "content") || map_get_value(parent_object, "summary"),
      "published" => map_get_value(parent_object, "published"),
      "attributedTo" => normalize_in_reply_to_ref(map_get_value(parent_object, "attributedTo")),
      "likes" => map_get_value(parent_object, "likes"),
      "likesCount" => map_get_value(parent_object, "likesCount"),
      "shares" => map_get_value(parent_object, "shares"),
      "sharesCount" => map_get_value(parent_object, "sharesCount"),
      "announcesCount" => map_get_value(parent_object, "announcesCount"),
      "replies" => map_get_value(parent_object, "replies"),
      "repliesCount" => map_get_value(parent_object, "repliesCount"),
      "comments" => map_get_value(parent_object, "comments"),
      "inReplyTo" =>
        normalize_in_reply_to_ref(
          map_get_value(parent_object, "inReplyTo") || map_get_value(parent_object, "in_reply_to")
        )
    }
  end

  defp normalize_reply_parent_post(_, _), do: nil

  defp parent_post_in_reply_to_ref(parent_post) when is_map(parent_post) do
    [
      map_get_value(parent_post, "inReplyTo"),
      map_get_value(parent_post, "in_reply_to")
    ]
    |> Enum.find_value(&normalize_in_reply_to_ref/1)
  end

  defp maybe_fetch_reply_parent_actor(parent_post) when is_map(parent_post) do
    attributed_to = extract_attributed_to_uri(parent_post)

    cond do
      !is_binary(attributed_to) ->
        nil

      local_actor_uri?(attributed_to) ->
        nil

      true ->
        case strict_fetch_remote_actor(attributed_to) do
          {:ok, actor} -> actor
          _ -> nil
        end
    end
  end

  defp extract_attributed_to_uri(post) when is_map(post) do
    post
    |> map_get_value("attributedTo")
    |> normalize_in_reply_to_ref()
  end

  defp local_actor_uri?(uri) when is_binary(uri) do
    ActivityPub.local_actor_prefixes()
    |> Enum.any?(fn prefix -> String.starts_with?(uri, prefix) end)
  end

  # Quick synchronous fetch for SEO meta tags (only on initial render)
  defp fetch_post_for_meta_tags(socket, post_id, true = _is_local) when is_integer(post_id) do
    # Local post - quick database lookup
    import Ecto.Query

    case Elektrine.Social.Message
         |> where([m], m.id == ^post_id)
         |> Elektrine.Repo.one()
         |> Elektrine.Repo.preload([:sender, :remote_actor]) do
      nil ->
        socket

      %{federated: true} = message ->
        if cached_federated_initial_render_safe?(message) do
          apply_cached_federated_local_post_for_initial_render(socket, message)
        else
          socket
        end

      message ->
        if AccessPolicy.can_view_local_post?(message, socket.assigns[:current_user]) do
          # Build meta tags from local message
          description = build_og_description(message.content)
          image = get_first_media_url(message.media_urls, message)

          sender_username =
            cond do
              message.remote_actor && Elektrine.Strings.present?(message.remote_actor.username) ->
                "@#{message.remote_actor.username}@#{message.remote_actor.domain}"

              message.sender && Elektrine.Strings.present?(message.sender.username) ->
                message.sender.username

              true ->
                "unknown"
            end

          title = message.title || "Post by #{sender_username}"

          socket
          |> assign(:page_title, title)
          |> assign(:meta_description, description)
          |> assign(:og_image, image)
          |> assign(:meta_robots, AccessPolicy.robots_for_local_post(message))
        else
          socket
        end
    end
  end

  defp fetch_post_for_meta_tags(socket, _post_id, true = _is_local), do: socket

  defp fetch_post_for_meta_tags(socket, post_id, false = _is_local) do
    if remote_activitypub_ref?(post_id) do
      load_cached_remote_post_socket(socket, post_id) || socket
    else
      fetch_remote_post_for_meta_tags(socket, post_id)
    end
  end

  defp cached_federated_initial_render_safe?(message) do
    not Elektrine.Strings.present?(message.title) and
      not Elektrine.Strings.present?(message.content) and
      is_list(message.media_urls) and message.media_urls != []
  end

  defp apply_cached_federated_local_post_for_initial_render(socket, message) do
    message = preload_cached_message_associations(message)

    cond do
      is_nil(message.remote_actor) ->
        socket

      AccessPolicy.can_view_local_post?(message, socket.assigns[:current_user]) ->
        post_object = build_post_object_from_message(message)
        apply_loaded_remote_post(socket, post_object, message.remote_actor, nil)

      true ->
        socket
    end
  end

  defp fetch_remote_post_for_meta_tags(socket, post_id) do
    # Remote post - only use a strict origin fetch so dead-render SEO does not
    # expose cached or fallback-recovered content.
    task =
      Task.async(fn ->
        strict_fetch_remote_object(post_id)
      end)

    case Task.yield(task, 3_000) || Task.shutdown(task) do
      {:ok, {:ok, post_object}} ->
        if AccessPolicy.remote_post_publicly_visible?(post_object) do
          content = post_object["content"] || post_object["summary"] || ""
          description = build_og_description(content)

          image =
            case post_object["attachment"] do
              [%{"url" => url} | _] when is_binary(url) -> url
              [%{"url" => [%{"href" => url} | _]} | _] when is_binary(url) -> url
              _ -> nil
            end

          actor_name =
            case normalize_in_reply_to_ref(post_object["attributedTo"]) do
              uri when is_binary(uri) ->
                username = SurfaceHelpers.extract_username_from_uri(uri)

                case URI.parse(uri) do
                  %URI{host: host} when is_binary(host) and host != "" ->
                    "@#{username}@#{host}"

                  _ ->
                    "@#{username}"
                end

              _ ->
                nil
            end

          page_title =
            post_object["name"] || (actor_name && "Post by #{actor_name}") || "Remote Post"

          socket
          |> assign(:page_title, page_title)
          |> assign(:meta_description, description)
          |> assign(:og_image, image)
          |> assign(:meta_robots, AccessPolicy.robots_for_remote_post(post_object))
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp load_cached_remote_post_socket(socket, post_id) when is_binary(post_id) do
    if cached_message = latest_local_message_for_post(post_id) do
      if is_nil(cached_message.remote_actor) do
        nil
      else
        post_object =
          cached_message
          |> build_post_object_from_message()
          |> maybe_enrich_cached_federated_post(cached_message)

        apply_loaded_remote_post(socket, post_object, cached_message.remote_actor, nil)
      end
    end
  end

  defp build_modal_post(socket) do
    cond do
      socket.assigns.is_local_post && socket.assigns.local_message ->
        socket.assigns.local_message

      socket.assigns.remote_actor ->
        inserted_at =
          case socket.assigns.post && socket.assigns.post["published"] do
            nil ->
              DateTime.utc_now()

            date_string ->
              case DateTime.from_iso8601(date_string) do
                {:ok, datetime, _} -> datetime
                _ -> DateTime.utc_now()
              end
          end

        %{
          remote_actor: socket.assigns.remote_actor,
          content: socket.assigns.post && socket.assigns.post["content"],
          inserted_at: inserted_at,
          activitypub_id: socket.assigns.post && socket.assigns.post["id"],
          like_count: modal_base_like_count(socket)
        }

      true ->
        nil
    end
  end

  defp modal_base_like_count(socket) do
    cond do
      is_map(socket.assigns[:lemmy_counts]) and
          not is_nil(Map.get(socket.assigns.lemmy_counts, :score)) ->
        Map.get(socket.assigns.lemmy_counts, :score)

      is_map(socket.assigns[:post]) and is_map(socket.assigns.post["_lemmy"]) and
          not is_nil(socket.assigns.post["_lemmy"]["score"]) ->
        socket.assigns.post["_lemmy"]["score"]

      is_map(socket.assigns[:post]) and not is_nil(socket.assigns.post["like_count"]) ->
        socket.assigns.post["like_count"]

      is_map(socket.assigns[:local_message]) and
          not is_nil(socket.assigns.local_message.like_count) ->
        socket.assigns.local_message.like_count

      is_map(socket.assigns[:post]) and is_map(socket.assigns.post["_mastodon"]) and
          not is_nil(socket.assigns.post["_mastodon"]["favourites_count"]) ->
        socket.assigns.post["_mastodon"]["favourites_count"]

      is_map(socket.assigns[:post]) and not is_nil(socket.assigns.post["likes"]) ->
        Elektrine.ActivityPub.Helpers.get_collection_total(socket.assigns.post["likes"])

      true ->
        0
    end
  end

  # Build OG description from post content (strip HTML, truncate)
  defp build_og_description(nil), do: nil

  defp build_og_description(content) when is_binary(content) do
    content
    |> HtmlSanitizeEx.strip_tags()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 200)
    |> case do
      "" -> nil
      desc -> if String.length(content) > 200, do: desc <> "...", else: desc
    end
  end

  defp build_og_description(_), do: nil

  # Get first media URL for OG image
  defp get_first_media_url(nil, _context), do: nil
  defp get_first_media_url([], _context), do: nil

  defp get_first_media_url(urls, context) when is_list(urls) do
    Enum.find_value(urls, fn
      url when is_binary(url) ->
        if Elektrine.Strings.present?(url) do
          full_url = message_attachment_url(url, context)

          if is_binary(full_url) &&
               String.match?(full_url, ~r/\.(jpe?g|png|gif|webp|svg)(\?.*)?$/i) do
            full_url
          else
            nil
          end
        end

      _ ->
        nil
    end)
  end

  defp get_first_media_url(_, _context), do: nil

  defp apply_loaded_remote_post(socket, post_object, remote_actor, community_actor) do
    post_id = normalize_in_reply_to_ref(post_object["id"] || post_object["url"])
    local_message = latest_local_message_for_post(post_id)

    if AccessPolicy.can_view_remote_post?(
         post_object,
         local_message,
         socket.assigns[:current_user]
       ) do
      do_apply_loaded_remote_post(
        socket,
        post_object,
        remote_actor,
        community_actor,
        local_message
      )
    else
      deny_remote_post_access(socket)
    end
  rescue
    error in Postgrex.Error ->
      if unique_activitypub_violation?(error) do
        Logger.warning(
          "Resolved duplicate ActivityPub post while applying remote post #{inspect(post_object["id"] || post_object["url"])}"
        )

        post_id = normalize_in_reply_to_ref(post_object["id"] || post_object["url"])

        case latest_local_message_for_post(post_id) do
          %Elektrine.Social.Message{} = local_message ->
            do_apply_loaded_remote_post(
              socket,
              post_object,
              remote_actor,
              community_actor,
              local_message
            )

          _ ->
            socket
            |> assign(:loading, false)
            |> assign(:load_error, "Post is already being cached. Refresh and try again.")
        end
      else
        reraise error, __STACKTRACE__
      end
  end

  defp do_apply_loaded_remote_post(
         socket,
         post_object,
         remote_actor,
         community_actor,
         local_message
       ) do
    local_message = resolve_local_message_for_post(local_message, post_object)
    local_community_uri = DiscussionSource.community_uri_from_local_message(local_message)

    community_actor =
      cond do
        community_actor ->
          community_actor

        is_binary(local_community_uri) ->
          case strict_fetch_remote_actor(local_community_uri) do
            {:ok, actor} -> actor
            _ -> nil
          end

        true ->
          nil
      end

    discussion_source =
      DiscussionSource.remote_discussion_source(
        post_object["id"] || post_object["url"],
        post_object,
        local_message
      )

    is_community_post = discussion_source == :lemmy

    {is_following_author, is_pending_author} =
      remote_follow_state(socket.assigns[:current_user], remote_actor)

    {is_following_community, is_pending_community} =
      if socket.assigns[:current_user] && community_actor do
        if Elektrine.Profiles.following_remote_actor?(
             socket.assigns.current_user.id,
             community_actor.id
           ) do
          {true, false}
        else
          case Elektrine.Profiles.get_follow_to_remote_actor(
                 socket.assigns.current_user.id,
                 community_actor.id
               ) do
            %{pending: true} -> {false, true}
            _ -> {false, false}
          end
        end
      else
        {false, false}
      end

    if socket.assigns[:current_user] && community_actor do
      Phoenix.PubSub.subscribe(
        Elektrine.PubSub,
        "user:#{socket.assigns.current_user.id}:timeline"
      )
    end

    socket =
      socket
      |> assign(:loading, false)
      |> assign(:replies_loading, true)
      |> assign(:pending_initial_comment_reveal, false)
      |> assign(
        :page_title,
        post_object["name"] || "Post by @#{remote_actor.username}@#{remote_actor.domain}"
      )
      |> assign(:post, post_object)
      |> assign(:meta_robots, AccessPolicy.robots_for_remote_post(post_object))
      |> assign(:remote_actor, remote_actor)
      |> assign(:community_actor, community_actor)
      |> assign(
        :community_stats,
        resolved_community_stats(community_actor, socket.assigns[:community_stats])
      )
      |> assign(:community_lookup_complete, true)
      |> assign(:is_community_post, is_community_post)
      |> assign(:is_following_community, is_following_community)
      |> assign(:is_pending_community, is_pending_community)
      |> assign(:is_following_author, is_following_author)
      |> assign(:is_pending_author, is_pending_author)
      |> assign_remote_author_follow_maps(remote_actor, is_following_author, is_pending_author)
      |> assign(
        :post_reactions,
        merge_remote_post_reactions(socket.assigns.post_reactions, post_object, local_message)
      )
      |> assign(:awaiting_initial_comment_counts, discussion_source == :lemmy)

    _ = Elektrine.Messaging.SyncRemoteCountsWorker.enqueue(post_object)

    socket =
      if local_message do
        local_message =
          local_message
          |> maybe_repair_local_message_submitted_link(post_object, remote_actor.domain)
          |> maybe_enqueue_submitted_link_repair()
          |> maybe_apply_initial_remote_counts(post_object)

        socket
        |> assign(:local_message, local_message)
        |> assign_local_first_post(local_message, post_object)
        |> maybe_assign_cached_lemmy_counts(local_message)
        |> assign_reply_parent_fallback(post_object, local_message)
        |> ensure_submitted_link_preview(post_object, local_message, remote_actor.domain)
        |> maybe_track_trust_detail_view(local_message, "remote_post_detail")
      else
        socket
        |> assign(:local_message, nil)
        |> assign_reply_parent_fallback(post_object, nil)
      end

    socket =
      if socket.assigns[:current_user] do
        interactions =
          load_detail_post_interactions(
            post_object,
            local_message,
            socket.assigns.current_user.id
          )

        user_saves =
          if local_message do
            saved = Social.post_saved?(socket.assigns.current_user.id, local_message.id)

            [local_message.id, local_message.activitypub_id, local_message.activitypub_url]
            |> Enum.reject(&is_nil/1)
            |> Enum.map(&PostInteractions.normalize_key/1)
            |> Enum.uniq()
            |> Enum.reduce(socket.assigns.user_saves, fn key, acc ->
              Map.put(acc, key, saved)
            end)
          else
            socket.assigns.user_saves
          end

        socket
        |> assign(:post_interactions, interactions)
        |> assign(:user_saves, user_saves)
      else
        socket
      end

    send(self(), {:load_reply_parent, post_object})

    socket =
      if local_message do
        assign(socket, :cached_replies_requested, true)
      else
        socket
      end

    if local_message do
      send(self(), {:load_replies_for_cached, local_message})
    end

    send(self(), {:hydrate_loaded_remote_post, post_object, remote_actor})

    send(self(), {:load_platform_counts, post_object["id"]})

    if community_actor && community_actor.actor_type == "Group" do
      send(self(), :load_community_stats)
    end

    socket
  end

  defp deny_remote_post_access(socket) do
    socket
    |> assign(:remote_post_load_ref, nil)
    |> assign(:loading, false)
    |> assign(:load_error, "Post not found")
    |> push_navigate(to: ~p"/")
  end

  defp fetch_platform_counts_result(post_id, current_post, local_message) do
    count_lookup_post = platform_count_lookup_post(post_id, current_post, local_message)

    discussion_source =
      DiscussionSource.remote_discussion_source(post_id, current_post, local_message)

    cond do
      discussion_source == :lemmy ->
        %{
          mastodon_counts: nil,
          lemmy_counts: Elektrine.ActivityPub.LemmyApi.fetch_post_counts(post_id),
          lemmy_comment_counts: Elektrine.ActivityPub.LemmyApi.fetch_comment_counts(post_id),
          fresh_post: nil
        }

      Elektrine.ActivityPub.MastodonApi.count_api_compatible?(count_lookup_post) ->
        %{
          mastodon_counts:
            Elektrine.ActivityPub.MastodonApi.fetch_status_counts_for_post(count_lookup_post),
          lemmy_counts: nil,
          lemmy_comment_counts: nil,
          fresh_post: nil
        }

      true ->
        fresh_post =
          if current_post do
            case strict_fetch_remote_object(post_id) do
              {:ok, fresh_post} -> fresh_post
              _ -> nil
            end
          else
            nil
          end

        %{
          mastodon_counts: nil,
          lemmy_counts: nil,
          lemmy_comment_counts: nil,
          fresh_post: fresh_post
        }
    end
  end

  defp platform_count_lookup_post(post_id, current_post, local_message) do
    %{
      activitypub_id:
        first_platform_count_ref([
          post_id,
          field_value(current_post, ["id", :id]),
          field_value(local_message, [:activitypub_id, "activitypub_id"])
        ]),
      activitypub_url:
        first_platform_count_ref([
          field_value(local_message, [:activitypub_url, "activitypub_url"]),
          field_value(current_post, ["activitypub_url", :activitypub_url]),
          field_value(current_post, ["url", :url])
        ])
    }
  end

  defp first_platform_count_ref(refs) do
    refs
    |> Enum.map(&normalize_in_reply_to_ref/1)
    |> Enum.find(&Elektrine.Strings.present?/1)
  end

  defp apply_platform_counts_result(socket, result) do
    mastodon_counts = Map.get(result, :mastodon_counts)
    lemmy_counts = Map.get(result, :lemmy_counts)
    lemmy_comment_counts = Map.get(result, :lemmy_comment_counts)
    fresh_post = Map.get(result, :fresh_post)

    if is_map(lemmy_comment_counts) and lemmy_comment_counts != %{} do
      Task.start(fn ->
        Elektrine.ActivityPub.LemmyCommentBackfill.apply_comment_counts(lemmy_comment_counts)
      end)
    end

    socket =
      if fresh_post do
        _ = Elektrine.Messaging.SyncRemoteCountsWorker.enqueue(fresh_post)
        assign(socket, :post, Map.merge(socket.assigns.post || %{}, fresh_post))
      else
        socket
      end

    platform_counts = platform_counts_from_result(mastodon_counts, lemmy_counts, fresh_post)
    platform_metadata = platform_metadata_from_result(mastodon_counts, lemmy_counts, fresh_post)

    socket =
      case latest_local_message_for_post(field_value(socket.assigns[:post], ["id", :id])) do
        %{} = refreshed_local_message ->
          socket
          |> assign(:local_message, refreshed_local_message)
          |> assign_local_first_post(refreshed_local_message, socket.assigns[:post])

        _ ->
          socket
      end
      |> maybe_apply_platform_counts_to_local_message(platform_counts, platform_metadata)

    socket =
      assign(
        socket,
        :post_reactions,
        merge_remote_post_reactions(
          socket.assigns[:post_reactions] || %{},
          socket.assigns[:post],
          socket.assigns[:local_message]
        )
      )

    socket
    |> assign(:mastodon_counts, mastodon_counts)
    |> assign(:lemmy_counts, lemmy_counts)
    |> assign(:lemmy_comment_counts, lemmy_comment_counts)
    |> maybe_apply_lemmy_comment_counts(lemmy_comment_counts)
  end

  defp platform_counts_from_result(mastodon_counts, _lemmy_counts, _fresh_post)
       when is_map(mastodon_counts) do
    %{
      like_count: positive_display_count(Map.get(mastodon_counts, :favourites_count)),
      reply_count: positive_display_count(Map.get(mastodon_counts, :replies_count)),
      share_count: positive_display_count(Map.get(mastodon_counts, :reblogs_count)),
      quote_count: positive_display_count(Map.get(mastodon_counts, :quotes_count))
    }
    |> nonzero_platform_counts()
  end

  defp platform_counts_from_result(_mastodon_counts, lemmy_counts, _fresh_post)
       when is_map(lemmy_counts) do
    %{
      like_count: positive_display_count(Map.get(lemmy_counts, :score)),
      reply_count: positive_display_count(Map.get(lemmy_counts, :comments)),
      share_count: nil,
      upvotes: positive_display_count(Map.get(lemmy_counts, :upvotes)),
      downvotes: positive_display_count(Map.get(lemmy_counts, :downvotes)),
      score: positive_display_count(Map.get(lemmy_counts, :score))
    }
    |> nonzero_platform_counts()
  end

  defp platform_counts_from_result(_mastodon_counts, _lemmy_counts, fresh_post)
       when is_map(fresh_post) do
    %{
      like_count:
        positive_display_count(APHelpers.extract_interaction_count(fresh_post, "likes")),
      reply_count:
        positive_display_count(APHelpers.extract_interaction_count(fresh_post, "replies")),
      share_count:
        positive_display_count(APHelpers.extract_interaction_count(fresh_post, "shares")),
      quote_count: positive_display_count(remote_status_quote_count(fresh_post))
    }
    |> nonzero_platform_counts()
  end

  defp platform_counts_from_result(_, _, _), do: nil

  defp nonzero_platform_counts(counts) when is_map(counts) do
    if Enum.any?(
         [:like_count, :reply_count, :share_count, :quote_count],
         &positive_platform_count?(Map.get(counts, &1))
       ) do
      counts
    end
  end

  defp positive_platform_count?(count), do: is_integer(count) and count > 0

  defp platform_metadata_from_result(mastodon_counts, _lemmy_counts, _fresh_post)
       when is_map(mastodon_counts) do
    mastodon_counts
    |> Map.get(:status_metadata)
    |> normalize_metadata()
  end

  defp platform_metadata_from_result(_mastodon_counts, _lemmy_counts, fresh_post)
       when is_map(fresh_post) do
    remote_status_metadata_from_post(fresh_post)
  end

  defp platform_metadata_from_result(_, _, _), do: %{}

  defp maybe_apply_initial_remote_counts(local_message, post_object) when is_map(local_message) do
    counts = platform_counts_from_result(nil, nil, post_object)
    metadata = platform_metadata_from_result(nil, nil, post_object)

    case sync_local_message_platform_counts(local_message, counts || %{}, metadata) do
      %{} = updated_message -> updated_message
      _ -> local_message
    end
  end

  defp maybe_apply_initial_remote_counts(local_message, _post_object), do: local_message

  defp remote_status_metadata_from_post(post) when is_map(post) do
    quote_count = remote_status_quote_count(post)

    %{}
    |> maybe_put_platform_status_metadata(
      "emoji_reactions",
      post["emoji_reactions"] || get_in(post, ["pleroma", "emoji_reactions"]) ||
        misskey_emoji_reactions(post["reactions"])
    )
    |> maybe_put_platform_status_metadata("quotes_count", if(quote_count > 0, do: quote_count))
    |> maybe_put_platform_status_metadata(
      "quote",
      post["quote"] || post["renote"] || get_in(post, ["pleroma", "quote"])
    )
    |> maybe_put_platform_status_metadata(
      "quote_id",
      post["quote_id"] || post["renoteId"] || get_in(post, ["pleroma", "quote_id"])
    )
    |> maybe_put_platform_status_metadata(
      "quote_url",
      post["quoteUrl"] || post["quoteUri"] || post["quote_url"] ||
        post["_misskey_quote"] ||
        get_in(post, ["pleroma", "quote_url"])
    )
    |> maybe_put_platform_status_metadata("card", post["card"])
    |> maybe_put_platform_status_metadata("application", post["application"] || post["app"])
    |> maybe_put_platform_status_metadata("language", post["language"])
    |> maybe_put_platform_status_metadata(
      "media_attachments",
      post["media_attachments"] || post["files"]
    )
    |> maybe_put_platform_status_metadata("pleroma", post["pleroma"])
    |> maybe_put_platform_status_metadata("misskey", post["misskey"])
  end

  defp remote_status_quote_count(post) when is_map(post) do
    normalize_display_count(
      post["quotes_count"] ||
        post["quote_count"] ||
        post["quotesCount"] ||
        post["quoteCount"] ||
        post["quotedCount"] ||
        get_in(post, ["pleroma", "quotes_count"])
    )
  end

  defp maybe_apply_platform_counts_to_local_message(socket, nil, metadata) do
    metadata = normalize_metadata(metadata)

    socket =
      update(socket, :post, fn
        %{} = post -> Counts.apply_status_metadata_to_post_object(post, metadata)
        post -> post
      end)

    if map_size(metadata) > 0 do
      local_message =
        resolve_local_message_for_post(socket.assigns[:local_message], socket.assigns[:post])

      case sync_local_message_platform_counts(local_message, %{}, metadata) do
        %{} = local_message -> assign(socket, :local_message, local_message)
        _ -> socket
      end
    else
      socket
    end
  end

  defp maybe_apply_platform_counts_to_local_message(socket, counts, metadata)
       when is_map(counts) do
    metadata = normalize_metadata(metadata)

    socket =
      update(socket, :post, fn
        %{} = post ->
          post
          |> Counts.apply_counts_to_post_object(counts)
          |> Counts.apply_status_metadata_to_post_object(metadata)

        post ->
          post
      end)

    local_message =
      resolve_local_message_for_post(socket.assigns[:local_message], socket.assigns[:post])

    case sync_local_message_platform_counts(local_message, counts, metadata) do
      %{} = local_message -> assign(socket, :local_message, local_message)
      _ -> socket
    end
  end

  defp sync_local_message_platform_counts(%{id: message_id} = local_message, counts, metadata)
       when is_integer(message_id) do
    {count_updates, updated_message} =
      DisplayCounts.merge_platform_count_updates(local_message, counts)

    merged_metadata =
      local_message.media_metadata
      |> merge_original_platform_counts(counts)
      |> merge_platform_status_metadata(metadata)

    metadata_changed? = merged_metadata != normalize_metadata(local_message.media_metadata)

    updates =
      count_updates
      |> maybe_put_metadata_update(metadata_changed?, merged_metadata)

    if updates != [] do
      import Ecto.Query

      Elektrine.Repo.update_all(
        from(m in Elektrine.Social.Message, where: m.id == ^message_id),
        set: Keyword.put(updates, :updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
      )

      maybe_broadcast_platform_counts(message_id, updated_message, count_updates)
    end

    if metadata_changed? do
      %{updated_message | media_metadata: merged_metadata}
    else
      updated_message
    end
  rescue
    error in Postgrex.Error ->
      if unique_activitypub_violation?(error) do
        case resolve_local_message_for_post(local_message, nil) do
          %{id: resolved_id} = resolved_message when resolved_id != message_id ->
            sync_local_message_platform_counts(resolved_message, counts, metadata)

          _ ->
            local_message
        end
      else
        reraise error, __STACKTRACE__
      end
  end

  defp sync_local_message_platform_counts(local_message, _counts, _metadata), do: local_message

  defp maybe_put_metadata_update(updates, true, metadata),
    do: [{:media_metadata, metadata} | updates]

  defp maybe_put_metadata_update(updates, _metadata_changed?, _metadata), do: updates

  defp merge_original_platform_counts(metadata, counts) do
    metadata
    |> normalize_metadata()
    |> maybe_put_original_platform_count("original_like_count", Map.get(counts, :like_count))
    |> maybe_put_original_platform_count("original_reply_count", Map.get(counts, :reply_count))
    |> maybe_put_original_platform_count("original_share_count", Map.get(counts, :share_count))
  end

  defp merge_platform_status_metadata(metadata, status_metadata) do
    status_metadata = normalize_metadata(status_metadata)

    metadata
    |> normalize_metadata()
    |> maybe_put_platform_status_metadata(
      "emoji_reactions",
      Map.get(status_metadata, "emoji_reactions")
    )
    |> maybe_put_platform_status_metadata(
      "quotes_count",
      Map.get(status_metadata, "quotes_count")
    )
    |> maybe_put_platform_status_metadata("quote", Map.get(status_metadata, "quote"))
    |> maybe_put_platform_status_metadata("quote_id", Map.get(status_metadata, "quote_id"))
    |> maybe_put_platform_status_metadata("quote_url", Map.get(status_metadata, "quote_url"))
    |> maybe_put_platform_status_metadata("card", Map.get(status_metadata, "card"))
    |> maybe_put_platform_status_metadata("application", Map.get(status_metadata, "application"))
    |> maybe_put_platform_status_metadata("language", Map.get(status_metadata, "language"))
    |> maybe_put_platform_status_metadata(
      "media_attachments",
      Map.get(status_metadata, "media_attachments")
    )
    |> maybe_put_platform_status_metadata("pleroma", Map.get(status_metadata, "pleroma"))
    |> maybe_put_platform_status_metadata("misskey", Map.get(status_metadata, "misskey"))
  end

  defp maybe_put_platform_status_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_platform_status_metadata(metadata, _key, []), do: metadata

  defp maybe_put_platform_status_metadata(metadata, _key, %{} = value) when map_size(value) == 0,
    do: metadata

  defp maybe_put_platform_status_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp maybe_put_original_platform_count(metadata, key, value) when is_integer(value),
    do: Map.put(metadata, key, value)

  defp maybe_put_original_platform_count(metadata, _key, _value), do: metadata

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp maybe_broadcast_platform_counts(message_id, updated_message, count_updates) do
    if Keyword.has_key?(count_updates, :like_count) or
         Keyword.has_key?(count_updates, :reply_count) or
         Keyword.has_key?(count_updates, :share_count) do
      Elektrine.Social.Messages.broadcast_post_counts_updated(message_id, %{
        like_count: updated_message.like_count || 0,
        reply_count: updated_message.reply_count || 0,
        share_count: updated_message.share_count || 0
      })
    end
  end

  defp positive_display_count(value) do
    case normalize_display_count(value) do
      count when count > 0 -> count
      _ -> nil
    end
  end

  defp normalize_display_count(value) when is_integer(value), do: max(value, 0)

  defp normalize_display_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, _} -> max(count, 0)
      :error -> 0
    end
  end

  defp normalize_display_count(_), do: 0

  defp update_cached_post_object(socket, post_object) do
    local_message = socket.assigns[:local_message]
    existing_post = socket.assigns[:post] || %{}

    post_object =
      post_object
      |> Polls.merge_local_poll_data(local_message)
      |> maybe_preserve_cached_post_fields(existing_post)

    is_community_post =
      socket.assigns.is_community_post ||
        is_binary(DiscussionSource.find_community_uri(post_object)) ||
        is_binary(DiscussionSource.community_uri_from_local_message(local_message)) ||
        DiscussionSource.community_post_url?(post_object["id"] || "") ||
        DiscussionSource.community_post_url?(post_object["url"] || "")

    updated_socket =
      socket
      |> assign(:post, post_object)
      |> assign(:is_community_post, is_community_post)
      |> assign(:page_title, post_object["name"] || socket.assigns.page_title)
      |> assign(:meta_robots, AccessPolicy.robots_for_remote_post(post_object))
      |> assign_reply_parent_fallback(post_object, local_message)
      |> ensure_submitted_link_preview(
        post_object,
        local_message,
        socket.assigns[:remote_actor] && socket.assigns.remote_actor.domain
      )

    send(self(), {:load_reply_parent, post_object})

    updated_socket
  end

  defp apply_loaded_community_actor(socket, community_actor) do
    {is_following_community, is_pending_community} =
      if socket.assigns[:current_user] && community_actor do
        if Elektrine.Profiles.following_remote_actor?(
             socket.assigns.current_user.id,
             community_actor.id
           ) do
          {true, false}
        else
          case Elektrine.Profiles.get_follow_to_remote_actor(
                 socket.assigns.current_user.id,
                 community_actor.id
               ) do
            %{pending: true} -> {false, true}
            _ -> {false, false}
          end
        end
      else
        {false, false}
      end

    if community_actor && community_actor.actor_type == "Group" do
      send(self(), :load_community_stats)
    end

    socket
    |> assign(:community_actor, community_actor)
    |> assign(
      :community_stats,
      resolved_community_stats(community_actor, socket.assigns[:community_stats])
    )
    |> assign(:community_lookup_complete, true)
    |> assign(:is_community_post, true)
    |> assign(:is_following_community, is_following_community)
    |> assign(:is_pending_community, is_pending_community)
  end

  @impl true
  def handle_info({:load_local_post, message_id}, socket) do
    import Ecto.Query

    started_at = System.monotonic_time(:millisecond)

    message = fetch_local_message_for_detail(message_id)

    log_remote_post_timing("load_local_post", started_at,
      message_id: message_id,
      found: not is_nil(message),
      federated: message && message.federated
    )

    if message && AccessPolicy.can_view_local_post?(message, socket.assigns[:current_user]) do
      if message.federated && is_binary(message.activitypub_id) &&
           match?(%Elektrine.ActivityPub.Actor{}, message.remote_actor) do
        post_object = build_post_object_from_message(message)
        post_object = maybe_enrich_cached_federated_post(post_object, message)

        {:noreply,
         socket
         |> assign(:remote_post_load_ref, nil)
         |> apply_loaded_remote_post(post_object, message.remote_actor, nil)}
      else
        visible_replies =
          (message.replies || [])
          |> Enum.filter(&AccessPolicy.can_view_local_post?(&1, socket.assigns[:current_user]))

        message = %{message | replies: visible_replies}

        # Convert local message to ActivityPub-like format for the template
        sender = message.sender
        base_url = ElektrineWeb.Endpoint.url()

        # Build image attachments
        attachments =
          if message.media_urls && message.media_urls != [] do
            message.media_urls
            |> Enum.filter(&(is_binary(&1) && &1 != ""))
            |> Enum.map(fn url ->
              full_url = Elektrine.Uploads.attachment_url(url, message)

              %{
                "type" => "Image",
                "url" => full_url,
                "mediaType" => "image/jpeg"
              }
            end)
            |> Enum.filter(&(is_binary(&1["url"]) && &1["url"] != ""))
          else
            []
          end

        post_attributed_to =
          case sender do
            %{username: username} when is_binary(username) and username != "" ->
              "#{base_url}/users/#{username}"

            _ ->
              nil
          end

        metadata = local_message_metadata(message)

        post_object = %{
          "id" => "#{base_url}/posts/#{message.id}",
          "type" => "Note",
          "content" => message.content,
          "published" => NaiveDateTime.to_iso8601(message.inserted_at) <> "Z",
          "attributedTo" => post_attributed_to,
          "inReplyTo" => message_in_reply_to(message),
          "inReplyToAuthor" => metadata["inReplyToAuthor"],
          "inReplyToContent" => metadata["inReplyToContent"],
          "inReplyToTitle" => metadata["inReplyToTitle"],
          "attachment" => attachments,
          "name" => message.title,
          "_local" => true,
          "_local_message" => message
        }

        # Convert all visible local descendants to ActivityPub-like format for threaded rendering.
        local_reply_messages =
          case collect_local_reply_descendants(message.id) do
            [] -> message.replies || []
            replies -> replies
          end
          |> Enum.filter(&AccessPolicy.can_view_local_post?(&1, socket.assigns[:current_user]))

        local_replies =
          local_reply_messages
          |> cached_reply_maps(post_object["id"])
          |> then(&prepare_replies_for_render(socket, &1))

        page_title =
          message.title ||
            case sender do
              %{username: username} when is_binary(username) and username != "" ->
                "Post by #{username}"

              _ ->
                "Post"
            end

        {threaded_replies, thread_reply_actors} =
          build_threaded_replies_with_actor_cache(
            local_replies,
            post_object["id"],
            socket.assigns.comment_sort
          )

        local_post_key = Integer.to_string(message.id)

        reactions =
          from(r in Elektrine.Social.MessageReaction,
            where: r.message_id == ^message.id,
            preload: [:user, :remote_actor]
          )
          |> Elektrine.Repo.all()

        post_reactions =
          socket.assigns.post_reactions
          |> Map.put(local_post_key, reactions)
          |> SurfaceHelpers.merge_reply_reactions(local_replies)

        {post_interactions, user_saves} =
          if socket.assigns[:current_user] do
            {post_interactions, user_saves} =
              load_local_detail_user_state(
                socket.assigns.current_user.id,
                message,
                socket.assigns.post_interactions,
                socket.assigns.user_saves
              )

            reply_interactions =
              load_post_interactions(local_replies, socket.assigns.current_user.id)

            {Map.merge(post_interactions, reply_interactions), user_saves}
          else
            {socket.assigns.post_interactions, socket.assigns.user_saves}
          end

        updated_socket =
          socket
          |> assign(:loading, false)
          |> assign(:is_community_post, false)
          |> assign(:community_actor, nil)
          |> assign(:community_stats, %{members: 0, posts: 0})
          |> assign(:post, post_object)
          |> assign(:local_message, message)
          |> assign(:remote_actor, nil)
          |> assign(:page_title, page_title)
          |> assign(:replies, local_replies)
          |> assign(
            :quick_reply_recent_replies,
            SurfaceHelpers.recent_replies_for_preview(local_replies, post_object["id"])
          )
          |> assign(:threaded_replies, threaded_replies)
          |> assign(:thread_reply_actors, thread_reply_actors)
          |> assign(:replies_loading, false)
          |> assign(:replies_loaded, true)
          |> assign(:post_interactions, post_interactions)
          |> assign(:user_saves, user_saves)
          |> assign(:post_reactions, post_reactions)
          |> assign_reply_parent_fallback(post_object, message)
          |> ensure_submitted_link_preview(post_object, message, nil)
          |> sync_post_reply_counts(local_replies)
          |> maybe_queue_reply_counts_load()
          |> maybe_track_trust_detail_view(message, "post_detail")

        send(self(), {:load_reply_parent, post_object})

        {:noreply, updated_socket}
      end
    else
      {:noreply,
       socket
       |> assign(:loading, false)
       |> assign(:load_error, "Post not found")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:load_remote_post, post_id}, socket) do
    if cached_message = latest_local_message_for_post(post_id) do
      post_object =
        cached_message
        |> build_post_object_from_message()
        |> maybe_enrich_cached_federated_post(cached_message)

      {:noreply, apply_loaded_remote_post(socket, post_object, cached_message.remote_actor, nil)}
    else
      load_remote_post_from_origin(post_id, socket)
    end
  end

  def handle_info(
        {:remote_post_loaded, load_ref,
         {:ok, %{post: post_object, actor: remote_actor, community: community_actor}}},
        socket
      ) do
    if socket.assigns[:remote_post_load_ref] != load_ref do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:remote_post_load_ref, nil)
       |> apply_loaded_remote_post(post_object, remote_actor, community_actor)}
    end
  end

  def handle_info({:remote_post_loaded, load_ref, {:error, _reason}}, socket) do
    if socket.assigns[:remote_post_load_ref] != load_ref do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:remote_post_load_ref, nil)
       |> assign(:loading, false)
       |> assign(:load_error, "Failed to load remote post")
       |> put_flash(:error, "Failed to load remote post")}
    end
  end

  def handle_info({:remote_post_load_timeout, load_ref}, socket) do
    if socket.assigns[:remote_post_load_ref] != load_ref do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:remote_post_load_ref, nil)
       |> assign(:loading, false)
       |> assign(:load_error, "Remote server took too long to respond")
       |> put_flash(:error, "Remote server took too long to respond")}
    end
  end

  def handle_info({:hydrate_loaded_remote_post, post_object, remote_actor}, socket) do
    local_message =
      resolve_local_message_for_post(socket.assigns[:local_message], post_object) ||
        ensure_local_message_for_remote_post(post_object, remote_actor)

    local_message =
      local_message
      |> maybe_repair_local_message_submitted_link(post_object, remote_actor.domain)
      |> maybe_enqueue_submitted_link_repair()
      |> maybe_apply_initial_remote_counts(post_object)

    if AccessPolicy.can_view_remote_post?(
         post_object,
         local_message,
         socket.assigns[:current_user]
       ) do
      local_community_uri = DiscussionSource.community_uri_from_local_message(local_message)

      socket =
        if local_message do
          socket
          |> assign(:local_message, local_message)
          |> assign_local_first_post(local_message, post_object)
          |> assign(
            :community_actor,
            socket.assigns[:community_actor] || local_message_community_actor(local_message)
          )
          |> assign_reply_parent_fallback(post_object, local_message)
          |> ensure_submitted_link_preview(post_object, local_message, remote_actor.domain)
          |> maybe_track_trust_detail_view(local_message, "remote_post_detail")
        else
          socket
        end

      if local_message do
        unless socket.assigns[:cached_replies_requested] do
          send(self(), {:load_replies, post_object})
        end

        send(self(), {:load_reactions, post_object["id"]})
        Elektrine.ActivityPub.RefreshCountsWorker.schedule_single_refresh(local_message.id)
        maybe_schedule_remote_poll_refresh(local_message)

        if is_binary(local_community_uri) && is_nil(socket.assigns[:community_actor]) do
          send(self(), {:load_community_for_cached, post_object["id"], local_community_uri})
        end
      end

      {:noreply, socket}
    else
      {:noreply, deny_remote_post_access(socket)}
    end
  rescue
    error in Postgrex.Error ->
      if unique_activitypub_violation?(error) do
        post_id = normalize_in_reply_to_ref(post_object["id"] || post_object["url"])
        local_message = latest_local_message_for_post(post_id)

        {:noreply,
         socket
         |> assign(:local_message, local_message)
         |> assign_local_first_post(local_message, post_object)}
      else
        reraise error, __STACKTRACE__
      end
  end

  def handle_info({:load_community_for_cached, post_id}, socket) do
    fallback_community_uri =
      DiscussionSource.community_uri_from_local_message(socket.assigns[:local_message])

    handle_info({:load_community_for_cached, post_id, fallback_community_uri}, socket)
  end

  # Load community actor for cached community posts
  def handle_info({:load_community_for_cached, post_id, fallback_community_uri}, socket) do
    lookup_ref = System.unique_integer([:positive, :monotonic])
    parent = self()

    Task.start(fn ->
      result =
        if is_binary(fallback_community_uri) do
          community_actor =
            case strict_fetch_remote_actor(fallback_community_uri) do
              {:ok, community_actor} -> community_actor
              _ -> nil
            end

          %{post_object: nil, community_detected: true, community_actor: community_actor}
        else
          case strict_fetch_remote_object(post_id) do
            {:ok, post_object} ->
              community_uri = DiscussionSource.find_community_uri(post_object)

              community_actor =
                if community_uri do
                  case strict_fetch_remote_actor(community_uri) do
                    {:ok, community_actor} -> community_actor
                    _ -> nil
                  end
                else
                  nil
                end

              %{
                post_object: post_object,
                community_detected: is_binary(community_uri),
                community_actor: community_actor
              }

            _ ->
              %{post_object: nil, community_detected: false, community_actor: nil}
          end
        end

      send(parent, {:cached_community_loaded, lookup_ref, result})
    end)

    Process.send_after(self(), {:cached_community_lookup_timeout, lookup_ref}, 10_000)

    {:noreply, assign(socket, :community_lookup_ref, lookup_ref)}
  end

  def handle_info({:cached_community_loaded, lookup_ref, result}, socket) do
    if socket.assigns[:community_lookup_ref] != lookup_ref do
      {:noreply, socket}
    else
      socket = assign(socket, :community_lookup_ref, nil)

      socket =
        if result.community_detected do
          assign(socket, :is_community_post, true)
        else
          socket
        end

      socket =
        if is_map(result.post_object) do
          socket
          |> update_cached_post_object(result.post_object)
        else
          socket
        end

      socket =
        if result.community_actor do
          apply_loaded_community_actor(socket, result.community_actor)
        else
          assign(socket, :community_lookup_complete, true)
        end

      {:noreply, socket}
    end
  end

  def handle_info({:cached_community_lookup_timeout, lookup_ref}, socket) do
    if socket.assigns[:community_lookup_ref] != lookup_ref do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:community_lookup_ref, nil)
       |> assign(:community_lookup_complete, true)}
    end
  end

  def handle_info(:community_detected, socket) do
    {:noreply, assign(socket, :is_community_post, true)}
  end

  def handle_info({:cached_post_object_loaded, post_object}, socket) do
    {:noreply, update_cached_post_object(socket, post_object)}
  end

  # Handle community actor loaded for cached posts
  def handle_info({:community_loaded, community_actor}, socket) do
    {:noreply, apply_loaded_community_actor(socket, community_actor)}
  end

  def handle_info(:community_lookup_complete, socket) do
    {:noreply, assign(socket, :community_lookup_complete, true)}
  end

  def handle_info(:load_community_stats, socket) do
    case socket.assigns.community_actor do
      %{actor_type: "Group"} = community_actor ->
        _ =
          ElektrineSocial.RemoteUser.MetricsWorker.enqueue(community_actor.id, "community_stats")

        Process.send_after(
          self(),
          {:reload_remote_post_community_stats, community_actor.id, 1},
          1_500
        )

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:community_stats_loaded, %{} = stats}, socket) do
    {:noreply,
     assign(
       socket,
       :community_stats,
       merge_community_stats(socket.assigns[:community_stats] || %{members: 0, posts: 0}, stats)
     )}
  end

  def handle_info({:reload_remote_post_community_stats, actor_id, attempt}, socket) do
    if socket.assigns.community_actor && socket.assigns.community_actor.id == actor_id do
      stats = ElektrineSocial.RemoteUser.Metrics.cached_community_stats(actor_id)

      if community_stats_ready?(stats) || attempt >= 8 do
        send(self(), {:community_stats_loaded, stats})
        {:noreply, socket}
      else
        Process.send_after(
          self(),
          {:reload_remote_post_community_stats, actor_id, attempt + 1},
          1_500
        )

        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # Load replies for cached posts
  def handle_info({:load_replies_for_cached, msg}, socket) do
    started_at = System.monotonic_time(:millisecond)
    post_id = msg.activitypub_id || msg.activitypub_url
    post_url = msg.activitypub_url || post_id
    replies_count = Counts.cached_reply_count(msg)
    replies_object = Counts.cached_replies_object(msg, replies_count)
    comments_object = Counts.cached_comments_object(msg, replies_count)
    community_uri = DiscussionSource.community_uri_from_local_message(msg)

    local_replies =
      case local_replies_from_local_message(msg) do
        [] -> if is_binary(post_id), do: SurfaceHelpers.merge_local_replies([], post_id), else: []
        replies -> replies
      end

    local_replies = prepare_replies_for_render(socket, local_replies)

    {threaded_replies, thread_reply_actors} =
      build_threaded_replies_with_actor_cache(local_replies, post_id, socket.assigns.comment_sort)

    reply_interactions =
      if socket.assigns[:current_user] && local_replies != [] do
        load_post_interactions(local_replies, socket.assigns.current_user.id)
      else
        %{}
      end

    post_reactions =
      socket.assigns.post_reactions
      |> SurfaceHelpers.merge_reply_reactions(local_replies)

    is_community_post = PostUtilities.community_post?(msg)

    # Build a post object from the cached message for reply fetching.
    # Include URL/count metadata so fallback fetchers (context APIs) run when needed.
    post_object = %{
      "id" => post_id,
      "url" => post_url,
      "type" => if(is_community_post, do: "Page", else: "Note"),
      "audience" => community_uri,
      "to" => build_cached_post_audience(community_uri),
      "repliesCount" => replies_count,
      "replies" => replies_object,
      "comments" => comments_object
    }

    if is_binary(post_id) do
      send(self(), {:load_replies, post_object})
    end

    log_remote_post_timing("load_replies_for_cached", started_at,
      message_id: Map.get(msg, :id),
      post_id: post_id,
      cached_reply_count: replies_count,
      local_replies: length(local_replies)
    )

    {:noreply,
     socket
     |> assign(:replies, local_replies)
     |> assign(
       :quick_reply_recent_replies,
       SurfaceHelpers.recent_replies_for_preview(local_replies, post_id)
     )
     |> assign(:threaded_replies, threaded_replies)
     |> assign(:thread_reply_actors, thread_reply_actors)
     |> assign(
       :post_interactions,
       Map.merge(socket.assigns.post_interactions, reply_interactions)
     )
     |> assign(:post_reactions, post_reactions)
     |> assign(:replies_loaded, local_replies != [])
     |> assign(:replies_loading, is_binary(post_id) && local_replies == [])
     |> assign(:reply_sync_checked, false)
     |> sync_post_reply_counts(local_replies)
     |> maybe_queue_reply_counts_load()
     |> assign(:is_community_post, socket.assigns.is_community_post || is_community_post)}
  end

  def handle_info({:refresh_cached_replies, message_id, post_id, attempt}, socket) do
    current_message_id = field_value(socket.assigns[:local_message], :id)
    current_post_id = field_value(socket.assigns[:post], ["id", :id])

    if current_message_id == message_id && current_post_id == post_id do
      refreshed_local_message = refresh_local_message(socket.assigns[:local_message])

      local_replies =
        case local_replies_from_local_message(refreshed_local_message) do
          [] -> SurfaceHelpers.merge_local_replies([], post_id)
          replies -> replies
        end

      expected_count = reply_sync_expected_count(refreshed_local_message, socket.assigns[:post])

      previous_reply_ids =
        socket.assigns[:replies]
        |> List.wrap()
        |> Enum.map(&field_value(&1, ["id", :id, "_local_message_id"]))
        |> MapSet.new()

      current_reply_ids =
        local_replies
        |> List.wrap()
        |> Enum.map(&field_value(&1, ["id", :id, "_local_message_id"]))
        |> MapSet.new()

      if local_replies != [] and current_reply_ids != previous_reply_ids do
        send(self(), {:replies_loaded, [], post_id})
      end

      if attempt >= @cached_reply_poll_max_attempts ||
           length(local_replies) >= max(expected_count, if(local_replies == [], do: 0, else: 1)) do
        if local_replies == [] or current_reply_ids == previous_reply_ids do
          send(self(), {:cached_reply_sync_finished, message_id, post_id})
        end

        {:noreply, socket}
      else
        Process.send_after(
          self(),
          {:refresh_cached_replies, message_id, post_id, attempt + 1},
          @cached_reply_poll_interval_ms
        )

        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:cached_reply_sync_finished, message_id, post_id}, socket) do
    current_message_id = field_value(socket.assigns[:local_message], :id)
    current_post_id = field_value(socket.assigns[:post], ["id", :id])

    if current_message_id == message_id && current_post_id == post_id do
      replies_present? =
        socket.assigns[:replies]
        |> List.wrap()
        |> Enum.any?()

      {:noreply,
       socket
       |> assign(:replies_loading, false)
       |> assign(:replies_loaded, replies_present?)
       |> assign(:pending_initial_comment_reveal, false)
       |> assign(:awaiting_initial_comment_counts, false)
       |> assign(:reply_sync_checked, true)}
    else
      {:noreply, socket}
    end
  end

  # Load interactions for the main post immediately (for cached posts)
  def handle_info({:load_main_post_interactions, msg}, socket) do
    if socket.assigns[:current_user] && msg.activitypub_id do
      # Build a minimal post object for load_post_interactions
      post_object = %{"id" => msg.activitypub_id}
      interactions = load_post_interactions([post_object], socket.assigns.current_user.id)

      # Preserve current optimistic main-post state when async hydration arrives later.
      updated_interactions = Map.merge(interactions, socket.assigns.post_interactions)
      {:noreply, assign(socket, :post_interactions, updated_interactions)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:load_reply_parent, post_object}, socket) when is_map(post_object) do
    started_at = System.monotonic_time(:millisecond)
    local_message = socket.assigns[:local_message]
    in_reply_to = extract_post_in_reply_to(post_object, local_message)
    socket = assign_reply_parent_fallback(socket, post_object, local_message)
    socket = hydrate_ancestor_surface_data(socket, socket.assigns.reply_ancestors)

    log_remote_post_timing("load_reply_parent", started_at,
      post_id: field_value(post_object, ["id", :id]),
      in_reply_to: is_binary(in_reply_to)
    )

    if is_binary(in_reply_to) do
      result = resolve_reply_ancestor_chain(in_reply_to)
      send(self(), {:reply_ancestors_loaded, in_reply_to, result})
    end

    {:noreply, socket}
  end

  def handle_info({:load_reply_parent, _}, socket), do: {:noreply, socket}

  def handle_info({:reload_local_post, message_id}, socket) do
    send(self(), {:load_local_post, message_id})
    {:noreply, socket}
  end

  def handle_info({:reply_ancestors_loaded, in_reply_to, {:ok, ancestors}}, socket) do
    if socket.assigns.in_reply_to == in_reply_to do
      case ancestors do
        [%{post: parent_post, actor: parent_actor} | _] ->
          {:noreply,
           socket
           |> assign(:reply_parent, parent_post)
           |> assign(:reply_parent_actor, parent_actor)
           |> assign(:reply_ancestors, ancestors)
           |> hydrate_ancestor_surface_data(ancestors)}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:reply_ancestors_loaded, _in_reply_to, {:error, _reason}}, socket) do
    {:noreply, socket}
  end

  def handle_info({:load_replies, post_object}, socket) do
    handle_info({:load_replies, post_object, []}, socket)
  end

  def handle_info({:refresh_remote_poll, message_id}, socket) do
    _ = Elektrine.ActivityPub.FetchRemotePollWorker.enqueue(message_id)
    Process.send_after(self(), {:reload_refreshed_poll, message_id}, 1_000)
    {:noreply, socket}
  end

  def handle_info({:reload_refreshed_poll, message_id}, socket) do
    refreshed_message =
      message_id
      |> Messaging.get_message()
      |> preload_cached_message_associations()

    if refreshed_message do
      {:noreply,
       socket
       |> assign(:local_message, refreshed_message)
       |> assign_local_first_post(refreshed_message, socket.assigns[:post])}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:load_replies, post_object, opts}, socket) when is_map(post_object) do
    started_at = System.monotonic_time(:millisecond)
    post_id = post_object["id"]
    force_sync = Keyword.get(opts, :force_sync, false)

    local_message =
      resolve_local_message_for_post(socket.assigns[:local_message], post_object) ||
        latest_local_message_for_post(post_id)

    if is_nil(local_message) do
      {:noreply,
       socket
       |> assign(:replies_loading, true)
       |> assign(:replies_loaded, false)}
    else
      socket =
        socket
        |> assign(:local_message, local_message)
        |> assign_reply_surface_from_db(post_id, current_local_replies(socket, post_id))
        |> assign(:reply_sync_checked, false)

      cached_replies = socket.assigns.replies

      should_sync_replies =
        should_sync_db_replies?(local_message, post_object, cached_replies, force_sync)

      {socket, local_message, synced_replies} =
        if should_sync_replies do
          refreshed_local_message = refresh_local_message(local_message)

          synced_socket =
            socket
            |> assign(:local_message, refreshed_local_message)
            |> assign_reply_surface_from_db(post_id, [])

          {synced_socket, refreshed_local_message, synced_socket.assigns[:replies] || []}
        else
          {socket, local_message, cached_replies}
        end

      should_continue_syncing =
        should_sync_db_replies?(local_message, post_object, synced_replies, false)

      socket =
        socket
        |> assign(:replies_loaded, synced_replies != [])
        |> assign(:replies_loading, should_continue_syncing && synced_replies == [])

      if should_continue_syncing do
        # Keep expensive remote thread hydration off the LiveView process so
        # websocket heartbeats are not starved on large community threads.
        _ =
          Elektrine.ActivityPub.ThreadBackfillWorker.enqueue(local_message.id, force: force_sync)

        if is_binary(post_id) do
          Process.send_after(
            self(),
            {:refresh_cached_replies, local_message.id, post_id, 1},
            @cached_reply_poll_interval_ms
          )
        end
      else
        send(self(), {:replies_loaded, [], post_id})
      end

      log_remote_post_timing("load_replies", started_at,
        post_id: post_id,
        local_message_id: local_message.id,
        cached_replies: length(cached_replies),
        synced_replies: length(synced_replies),
        should_sync: should_sync_replies,
        should_continue_syncing: should_continue_syncing,
        force_sync: force_sync
      )

      {:noreply, socket}
    end
  end

  def handle_info({:replies_loaded, replies, post_id}, socket) do
    local_message = resolve_local_message_for_post(socket.assigns[:local_message], post_id)

    local_first_replies =
      case local_replies_from_local_message(local_message) do
        [] -> SurfaceHelpers.merge_local_replies([], post_id)
        message_replies -> message_replies
      end

    merged_replies =
      if local_first_replies != [] do
        local_first_replies
      else
        SurfaceHelpers.merge_local_replies(replies, post_id)
      end

    merged_replies =
      if merged_replies == [] and socket.assigns.replies != [] do
        socket.assigns.replies
      else
        merged_replies
      end

    merged_replies = prepare_replies_for_render(socket, merged_replies)

    # Build threaded replies structure and cache actor lookups by URI.
    {threaded_replies, thread_reply_actors} =
      build_threaded_replies_with_actor_cache(
        merged_replies,
        post_id,
        socket.assigns.comment_sort
      )

    # Load interaction state for current user
    all_posts =
      if socket.assigns.post, do: [socket.assigns.post | merged_replies], else: merged_replies

    post_interactions =
      if socket.assigns[:current_user] do
        load_post_interactions(all_posts, socket.assigns.current_user.id)
      else
        %{}
      end

    post_reactions =
      socket.assigns.post_reactions
      |> SurfaceHelpers.merge_reply_reactions(merged_replies)

    reveal_after_comment_counts? =
      socket.assigns[:awaiting_initial_comment_counts] && merged_replies != []

    refreshed_local_message = refresh_local_message(local_message)

    {:noreply,
     socket
     |> assign(:local_message, refreshed_local_message)
     |> assign_local_first_post(refreshed_local_message, socket.assigns[:post])
     |> assign(:replies, merged_replies)
     |> assign(
       :quick_reply_recent_replies,
       SurfaceHelpers.recent_replies_for_preview(merged_replies, post_id)
     )
     |> assign(:threaded_replies, threaded_replies)
     |> assign(:thread_reply_actors, thread_reply_actors)
     |> sync_post_reply_counts(merged_replies)
     |> assign(:replies_loading, reveal_after_comment_counts?)
     |> assign(:replies_loaded, !reveal_after_comment_counts?)
     |> assign(:pending_initial_comment_reveal, reveal_after_comment_counts?)
     |> assign(:reply_sync_checked, true)
     |> assign(:post_interactions, post_interactions)
     |> assign(:post_reactions, post_reactions)
     |> maybe_queue_reply_counts_load()}
  end

  def handle_info({:load_platform_counts, post_id}, socket) do
    load_ref = System.unique_integer([:positive, :monotonic])
    parent = self()
    current_post = socket.assigns[:post]
    local_message = socket.assigns[:local_message]

    Task.start(fn ->
      started_at = System.monotonic_time(:millisecond)
      result = fetch_platform_counts_result(post_id, current_post, local_message)

      log_remote_post_timing("load_platform_counts", started_at,
        post_id: post_id,
        result: inspect(result, limit: 5, printable_limit: 200)
      )

      send(parent, {:platform_counts_loaded, load_ref, post_id, result})
    end)

    {:noreply, assign(socket, :platform_counts_load_ref, load_ref)}
  end

  # Older handler for older clients
  def handle_info({:load_lemmy_counts, post_id}, socket) do
    send(self(), {:load_platform_counts, post_id})
    {:noreply, socket}
  end

  def handle_info({:load_reactions, activitypub_id}, socket) do
    # Try to find local message for this ActivityPub ID and load reactions
    case Elektrine.Messaging.get_message_by_activitypub_id(activitypub_id) do
      nil ->
        {:noreply, socket}

      message ->
        import Ecto.Query

        reactions =
          from(r in Elektrine.Social.MessageReaction,
            where: r.message_id == ^message.id,
            preload: [:user, :remote_actor]
          )
          |> Elektrine.Repo.all()

        {:noreply,
         assign(
           socket,
           :post_reactions,
           socket.assigns.post_reactions
           |> Kernel.||(%{})
           |> Map.put(activitypub_id, reactions)
           |> merge_remote_post_reactions(socket.assigns[:post], socket.assigns[:local_message])
         )}
    end
  end

  def handle_info({:refresh_remote_counts, post_id}, socket) do
    refresh_ref = System.unique_integer([:positive, :monotonic])
    parent = self()
    current_post = socket.assigns[:post]
    local_message = socket.assigns[:local_message]

    Task.start(fn ->
      result = fetch_platform_counts_result(post_id, current_post, local_message)
      send(parent, {:remote_counts_refreshed, refresh_ref, post_id, result})
    end)

    {:noreply, assign(socket, :platform_counts_refresh_ref, refresh_ref)}
  end

  def handle_info({:platform_counts_loaded, load_ref, post_id, result}, socket) do
    if socket.assigns[:platform_counts_load_ref] != load_ref do
      {:noreply, socket}
    else
      Process.send_after(self(), {:refresh_remote_counts, post_id}, 60_000)

      {:noreply,
       socket
       |> assign(:platform_counts_load_ref, nil)
       |> apply_platform_counts_result(result)
       |> finalize_initial_comment_reveal()}
    end
  end

  def handle_info({:remote_counts_refreshed, refresh_ref, post_id, result}, socket) do
    if socket.assigns[:platform_counts_refresh_ref] != refresh_ref do
      {:noreply, socket}
    else
      Process.send_after(self(), {:refresh_remote_counts, post_id}, 30_000)

      {:noreply,
       socket
       |> assign(:platform_counts_refresh_ref, nil)
       |> apply_platform_counts_result(result)}
    end
  end

  def handle_info(:load_reply_counts, socket) do
    reply_count_posts = reply_count_lookup_posts(socket.assigns[:replies] || [])

    if reply_count_posts == [] do
      {:noreply, socket}
    else
      load_ref = System.unique_integer([:positive, :monotonic])
      parent = self()

      Task.start(fn ->
        started_at = System.monotonic_time(:millisecond)
        counts = Elektrine.ActivityPub.MastodonApi.fetch_statuses_counts(reply_count_posts)

        log_remote_post_timing("load_reply_counts", started_at,
          reply_count: length(reply_count_posts),
          loaded_count: map_size(counts)
        )

        send(parent, {:reply_counts_loaded, load_ref, counts})
      end)

      {:noreply, assign(socket, :reply_counts_load_ref, load_ref)}
    end
  end

  def handle_info(:refresh_reply_counts, socket) do
    reply_count_posts = reply_count_lookup_posts(socket.assigns[:replies] || [])

    if reply_count_posts == [] do
      {:noreply, socket}
    else
      refresh_ref = System.unique_integer([:positive, :monotonic])
      parent = self()

      Task.start(fn ->
        counts = Elektrine.ActivityPub.MastodonApi.fetch_statuses_counts(reply_count_posts)
        send(parent, {:reply_counts_refreshed, refresh_ref, counts})
      end)

      {:noreply, assign(socket, :reply_counts_refresh_ref, refresh_ref)}
    end
  end

  def handle_info({:reply_counts_loaded, load_ref, counts}, socket) do
    if socket.assigns[:reply_counts_load_ref] != load_ref do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh_reply_counts, 60_000)

      {:noreply,
       socket
       |> assign(:reply_counts_load_ref, nil)
       |> apply_reply_platform_counts(counts)}
    end
  end

  def handle_info({:reply_counts_refreshed, refresh_ref, counts}, socket) do
    if socket.assigns[:reply_counts_refresh_ref] != refresh_ref do
      {:noreply, socket}
    else
      Process.send_after(self(), :refresh_reply_counts, 30_000)

      {:noreply,
       socket
       |> assign(:reply_counts_refresh_ref, nil)
       |> apply_reply_platform_counts(counts)}
    end
  end

  def handle_info({:post_counts_updated, %{message_id: message_id, counts: counts}}, socket) do
    local_message = socket.assigns[:local_message]

    if local_message && local_message.id == message_id do
      updated_local_message = %{
        local_message
        | like_count: counts.like_count,
          share_count: counts.share_count,
          reply_count: counts.reply_count
      }

      updated_post = Counts.apply_counts_to_post_object(socket.assigns[:post], counts)

      updated_modal_post =
        case socket.assigns[:modal_post] do
          %{"id" => _id} = post -> Counts.apply_counts_to_post_object(post, counts)
          post -> post
        end

      updated_lemmy_counts =
        if socket.assigns[:post] do
          Map.put(
            socket.assigns.lemmy_counts || %{},
            :score,
            counts.like_count
          )
          |> Map.put(:comments, counts.reply_count)
        else
          socket.assigns.lemmy_counts
        end

      updated_mastodon_counts =
        if is_map(socket.assigns.mastodon_counts) do
          socket.assigns.mastodon_counts
          |> Map.put(:favourites_count, counts.like_count)
          |> Map.put(:reblogs_count, counts.share_count)
          |> Map.put(:replies_count, counts.reply_count)
        else
          socket.assigns.mastodon_counts
        end

      updated_post_interactions =
        reset_main_post_vote_delta(
          socket.assigns.post_interactions,
          socket.assigns.post,
          local_message
        )

      {:noreply,
       socket
       |> assign(:local_message, updated_local_message)
       |> assign(:post, updated_post)
       |> assign(:modal_post, updated_modal_post)
       |> assign(:post_interactions, updated_post_interactions)
       |> assign(:lemmy_counts, updated_lemmy_counts)
       |> assign(:mastodon_counts, updated_mastodon_counts)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:new_public_post, post}, socket) do
    root_message_id = field_value(socket.assigns[:local_message], :id)
    post_id = field_value(socket.assigns[:post], ["id", :id])

    if is_integer(root_message_id) and is_binary(post_id) and
         message_in_displayed_thread?(post, root_message_id) do
      send(self(), {:replies_loaded, [], post_id})
    end

    {:noreply, socket}
  end

  # Handle follow acceptance - update button state without refresh
  def handle_info({:follow_accepted, remote_actor_id}, socket) do
    # Only update if this is the community we're viewing
    if socket.assigns.community_actor && socket.assigns.community_actor.id == remote_actor_id do
      {:noreply,
       socket
       |> assign(:is_following_community, true)
       |> assign(:is_pending_community, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:poll_submitted_link_preview, _url, attempts_left}, socket)
      when attempts_left <= 0 do
    {:noreply, socket}
  end

  def handle_info({:poll_submitted_link_preview, url, attempts_left}, socket)
      when is_binary(url) and attempts_left > 0 do
    current_url = current_submitted_url(socket)

    if current_url != url do
      {:noreply, socket}
    else
      case Elektrine.Repo.get_by(Elektrine.Social.LinkPreview, url: url) do
        %Elektrine.Social.LinkPreview{status: "success"} = preview ->
          {:noreply, assign(socket, :submitted_link_preview, preview)}

        %Elektrine.Social.LinkPreview{status: "failed"} ->
          {:noreply, socket}

        _ ->
          Process.send_after(
            self(),
            {:poll_submitted_link_preview, url, attempts_left - 1},
            @submitted_preview_poll_interval_ms
          )

          {:noreply, socket}
      end
    end
  end

  # Catch-all for PubSub broadcasts we don't need to handle (e.g., presence_diff)
  def handle_info(%Phoenix.Socket.Broadcast{}, socket) do
    {:noreply, socket}
  end

  # Catch-all for other unhandled messages (e.g., :new_email from global PubSub)
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp load_remote_post_from_origin(post_id, socket) do
    load_ref = System.unique_integer([:positive, :monotonic])
    parent = self()

    Task.start(fn ->
      started_at = System.monotonic_time(:millisecond)

      result =
        case fetch_remote_object_for_detail(post_id) do
          {:ok, post_object} ->
            cached_message =
              latest_local_message_for_refs(activitypub_refs_for_post(post_object, post_id))

            author_uri =
              normalize_in_reply_to_ref(post_object["attributedTo"]) ||
                normalize_in_reply_to_ref(post_object["actor"])

            remote_actor =
              if match?(
                   %Elektrine.ActivityPub.Actor{},
                   cached_message && cached_message.remote_actor
                 ) do
                cached_message.remote_actor
              else
                case fetch_remote_actor_for_detail(author_uri) do
                  {:ok, actor} -> actor
                  _ -> nil
                end
              end

            if remote_actor do
              {:ok, %{post: post_object, actor: remote_actor, community: nil}}
            else
              {:error, :actor_not_found}
            end

          {:error, reason} ->
            {:error, reason}
        end

      log_remote_post_timing("load_remote_post", started_at,
        post_id: post_id,
        result:
          case result do
            {:ok, _} -> :ok
            {:error, reason} -> reason
          end
      )

      send(parent, {:remote_post_loaded, load_ref, result})
    end)

    Process.send_after(self(), {:remote_post_load_timeout, load_ref}, 15_000)

    {:noreply, assign(socket, :remote_post_load_ref, load_ref)}
  end

  defp latest_local_message_for_post(post_id) when is_binary(post_id) do
    case local_message_by_activitypub_ref(post_id) do
      %{} = message -> preload_cached_message_associations(message)
      _ -> nil
    end
  end

  defp latest_local_message_for_post(_), do: nil

  defp resolve_local_message_for_post(local_message, post_ref_or_object) do
    case latest_local_message_for_refs(
           activitypub_refs_for_post(post_ref_or_object, local_message)
         ) do
      %{} = resolved_message -> resolved_message
      _ -> local_message
    end
  end

  defp latest_local_message_for_refs(refs) when is_list(refs) do
    refs
    |> Enum.flat_map(&activitypub_ref_values/1)
    |> Enum.map(&normalize_in_reply_to_ref/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.find_value(&latest_local_message_for_post/1)
  end

  defp activitypub_refs_for_post(post_ref_or_object, local_message) do
    [
      field_value(post_ref_or_object, ["id", :id]),
      field_value(post_ref_or_object, ["url", :url]),
      field_value(post_ref_or_object, ["activitypub_id", :activitypub_id]),
      field_value(post_ref_or_object, ["activitypub_url", :activitypub_url]),
      post_ref_or_object,
      field_value(local_message, [:activitypub_id, "activitypub_id"]),
      field_value(local_message, [:activitypub_url, "activitypub_url"])
    ]
  end

  defp activitypub_ref_values(value) when is_binary(value), do: [value]

  defp activitypub_ref_values(values) when is_list(values),
    do: Enum.flat_map(values, &activitypub_ref_values/1)

  defp activitypub_ref_values(%{"id" => id}), do: activitypub_ref_values(id)
  defp activitypub_ref_values(%{"href" => href}), do: activitypub_ref_values(href)
  defp activitypub_ref_values(%{"url" => url}), do: activitypub_ref_values(url)
  defp activitypub_ref_values(%{id: id}), do: activitypub_ref_values(id)
  defp activitypub_ref_values(%{href: href}), do: activitypub_ref_values(href)
  defp activitypub_ref_values(%{url: url}), do: activitypub_ref_values(url)
  defp activitypub_ref_values(_), do: []

  defp local_message_by_activitypub_ref(post_id) when is_binary(post_id) do
    Messaging.get_message_by_activitypub_ref(post_id, cache: false)
  rescue
    error in Postgrex.Error ->
      if postgres_error_code(error) == :index_corrupted do
        Logger.error(
          "Postgres index corruption while loading ActivityPub ref: #{Exception.message(error)}"
        )

        nil
      else
        reraise error, __STACKTRACE__
      end
  end

  defp ensure_local_message_for_remote_post(post_object, remote_actor) when is_map(post_object) do
    post_id = normalize_in_reply_to_ref(post_object["id"] || post_object["url"])

    actor_uri =
      (remote_actor && remote_actor.uri) ||
        normalize_in_reply_to_ref(post_object["actor"]) ||
        normalize_in_reply_to_ref(post_object["attributedTo"])

    latest_local_message_for_post(post_id) ||
      case actor_uri do
        actor_uri when is_binary(actor_uri) ->
          case store_remote_post_safely(post_object, actor_uri) do
            {:ok, %Elektrine.Social.Message{} = message} ->
              preload_cached_message_associations(message)

            {:ok, _} ->
              latest_local_message_for_post(post_id)

            {:error, %Ecto.Changeset{errors: errors}} ->
              if Keyword.has_key?(errors, :activitypub_id) do
                latest_local_message_for_post(post_id)
              else
                nil
              end

            _ ->
              nil
          end

        _ ->
          nil
      end
  end

  defp ensure_local_message_for_remote_post(_, _), do: nil

  defp should_sync_db_replies?(
         %{id: message_id, federated: true} = local_message,
         post_object,
         local_replies,
         force_sync
       )
       when is_integer(message_id) and is_map(post_object) and is_list(local_replies) do
    force_sync || local_replies == [] ||
      reply_sync_expected_count(local_message, post_object) > length(local_replies)
  end

  defp should_sync_db_replies?(_, _, _, _), do: false

  defp reply_sync_expected_count(local_message, post_object) do
    post_reply_count = if is_map(post_object), do: post_object["reply_count"], else: nil
    replies_count = if is_map(post_object), do: post_object["repliesCount"], else: nil
    replies_collection = if is_map(post_object), do: post_object["replies"], else: nil
    comments_collection = if is_map(post_object), do: post_object["comments"], else: nil

    [
      if(is_map(local_message), do: Counts.cached_reply_count(local_message), else: 0),
      Counts.normalize_cached_reply_count(post_reply_count),
      Counts.normalize_cached_reply_count(replies_count),
      Counts.normalize_cached_reply_count(Counts.total_items_from_collection(replies_collection)),
      Counts.normalize_cached_reply_count(Counts.total_items_from_collection(comments_collection))
    ]
    |> Enum.max(fn -> 0 end)
  end

  defp refresh_local_message(%{id: message_id} = local_message) when is_integer(message_id) do
    case Elektrine.Repo.get(Elektrine.Social.Message, message_id) do
      %Elektrine.Social.Message{} = fresh_message ->
        %{local_message | reply_count: fresh_message.reply_count}

      _ ->
        local_message
    end
  end

  defp refresh_local_message(local_message), do: local_message

  defp assign_reply_surface_from_db(socket, post_id, preloaded_replies) do
    local_replies =
      cond do
        (message_replies = local_replies_from_local_message(socket.assigns[:local_message])) != [] ->
          message_replies

        is_list(preloaded_replies) and preloaded_replies != [] ->
          preloaded_replies

        is_binary(post_id) ->
          SurfaceHelpers.merge_local_replies([], post_id)

        true ->
          []
      end

    local_replies = prepare_replies_for_render(socket, local_replies)

    {threaded_replies, thread_reply_actors} =
      build_threaded_replies_with_actor_cache(local_replies, post_id, socket.assigns.comment_sort)

    all_posts =
      if socket.assigns.post, do: [socket.assigns.post | local_replies], else: local_replies

    post_interactions =
      if socket.assigns[:current_user] do
        load_post_interactions(all_posts, socket.assigns.current_user.id)
      else
        socket.assigns.post_interactions
      end

    post_reactions =
      socket.assigns.post_reactions
      |> SurfaceHelpers.merge_reply_reactions(local_replies)

    socket
    |> assign(:replies, local_replies)
    |> assign(
      :quick_reply_recent_replies,
      SurfaceHelpers.recent_replies_for_preview(local_replies, post_id)
    )
    |> assign(:threaded_replies, threaded_replies)
    |> assign(:thread_reply_actors, thread_reply_actors)
    |> assign(:post_interactions, post_interactions)
    |> assign(:post_reactions, post_reactions)
    |> sync_post_reply_counts(local_replies)
  end

  defp current_local_replies(socket, post_id) when is_binary(post_id) do
    current_post_id = field_value(socket.assigns[:post], ["id", :id])

    if current_post_id == post_id and is_list(socket.assigns[:replies]) do
      socket.assigns.replies
    else
      nil
    end
  end

  defp current_local_replies(_, _), do: nil

  defp local_replies_from_local_message(%{id: message_id, activitypub_id: parent_ap_id})
       when is_integer(message_id) and is_binary(parent_ap_id) do
    case collect_local_reply_descendants(message_id) do
      [] -> []
      messages -> cached_reply_maps(messages, parent_ap_id)
    end
  end

  defp local_replies_from_local_message(%{activitypub_id: parent_ap_id, replies: replies})
       when is_binary(parent_ap_id) and is_list(replies) and replies != [] do
    case collect_local_reply_descendants(replies) do
      [] -> []
      messages -> cached_reply_maps(messages, parent_ap_id)
    end
  end

  defp local_replies_from_local_message(%{id: message_id}) when is_integer(message_id) do
    case Messaging.get_message(message_id) do
      %{activitypub_id: parent_ap_id} when is_binary(parent_ap_id) ->
        case collect_local_reply_descendants(message_id) do
          [] -> []
          messages -> cached_reply_maps(messages, parent_ap_id)
        end

      _ ->
        []
    end
  end

  defp local_replies_from_local_message(_), do: []

  defp cached_reply_maps(messages, root_parent_ap_id) when is_list(messages) do
    parent_ap_ids =
      messages
      |> Enum.reduce(%{}, fn message, acc ->
        Map.put(acc, message.id, message.activitypub_id || message.activitypub_url)
      end)

    messages
    |> Enum.map(fn message ->
      parent_activitypub_id =
        if is_integer(message.reply_to_id) do
          Map.get(parent_ap_ids, message.reply_to_id, root_parent_ap_id)
        else
          root_parent_ap_id
        end

      Map.put(message, :parent_activitypub_id, parent_activitypub_id)
    end)
    |> SurfaceHelpers.convert_cached_messages_to_ap_format()
  end

  defp cached_reply_maps(_, _), do: []

  defp collect_local_reply_descendants(%{id: message_id}) when is_integer(message_id) do
    collect_local_reply_descendants(message_id)
  end

  defp collect_local_reply_descendants(replies) when is_list(replies) do
    replies
    |> Enum.map(fn
      %{id: id} when is_integer(id) -> id
      id when is_integer(id) -> id
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> collect_local_reply_descendants()
  end

  defp collect_local_reply_descendants(root_message_id) when is_integer(root_message_id) do
    collect_local_reply_descendants([root_message_id], MapSet.new(), [])
  end

  defp collect_local_reply_descendants(_, seen_ids, acc) when map_size(seen_ids) >= 5000,
    do: Enum.reverse(acc)

  defp collect_local_reply_descendants(parent_ids, seen_ids, acc) when is_list(parent_ids) do
    import Ecto.Query

    pending_parent_ids =
      parent_ids
      |> Enum.filter(&is_integer/1)
      |> Enum.uniq()

    if pending_parent_ids == [] do
      Enum.reverse(acc)
    else
      replies =
        Elektrine.Social.Message
        |> where([m], m.reply_to_id in ^pending_parent_ids and is_nil(m.deleted_at))
        |> order_by([m], asc: m.inserted_at)
        |> preload([:sender, :remote_actor])
        |> Elektrine.Repo.all()

      new_replies = Enum.reject(replies, &MapSet.member?(seen_ids, &1.id))

      if new_replies == [] do
        Enum.reverse(acc)
      else
        next_parent_ids = Enum.map(new_replies, & &1.id)
        next_seen_ids = Enum.reduce(new_replies, seen_ids, &MapSet.put(&2, &1.id))

        collect_local_reply_descendants(
          next_parent_ids,
          next_seen_ids,
          Enum.reverse(new_replies) ++ acc
        )
      end
    end
  end

  defp message_in_displayed_thread?(%{reply_to_id: reply_to_id}, root_message_id)
       when is_integer(root_message_id) do
    reply_descends_from_root?(reply_to_id, root_message_id, MapSet.new())
  end

  defp message_in_displayed_thread?(_, _), do: false

  defp reply_descends_from_root?(reply_to_id, root_message_id, _seen)
       when reply_to_id == root_message_id,
       do: true

  defp reply_descends_from_root?(reply_to_id, _root_message_id, _seen)
       when not is_integer(reply_to_id),
       do: false

  defp reply_descends_from_root?(reply_to_id, root_message_id, seen) do
    if MapSet.member?(seen, reply_to_id) do
      false
    else
      case Messaging.get_message(reply_to_id) do
        %{reply_to_id: parent_reply_to_id} ->
          reply_descends_from_root?(
            parent_reply_to_id,
            root_message_id,
            MapSet.put(seen, reply_to_id)
          )

        _ ->
          false
      end
    end
  end

  defp sync_post_reply_counts(socket, local_replies) when is_list(local_replies) do
    reply_count = loaded_reply_count(local_replies)

    local_message =
      resolve_local_message_for_post(socket.assigns[:local_message], socket.assigns[:post])

    persist_loaded_reply_count(local_message, reply_count)

    local_message =
      case local_message do
        %{} = message -> %{message | reply_count: max(message.reply_count || 0, reply_count)}
        other -> other
      end

    effective_reply_count =
      case local_message do
        %{} = message -> max(message.reply_count, reply_count)
        _ -> reply_count
      end

    socket
    |> assign(:local_message, local_message)
    |> assign(
      :post,
      apply_local_reply_count_to_post(socket.assigns[:post], effective_reply_count)
    )
  end

  defp persist_loaded_reply_count(%{id: message_id} = local_message, reply_count)
       when is_integer(message_id) and is_integer(reply_count) and reply_count > 0 do
    current_reply_count = local_message.reply_count || 0

    if reply_count > current_reply_count do
      import Ecto.Query

      {updated_rows, _} =
        Elektrine.Repo.update_all(
          from(m in Elektrine.Social.Message,
            where: m.id == ^message_id and (is_nil(m.reply_count) or m.reply_count < ^reply_count)
          ),
          set: [
            reply_count: reply_count,
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ]
        )

      if updated_rows > 0 do
        Elektrine.Social.Messages.broadcast_post_counts_updated(message_id, %{
          like_count: local_message.like_count || 0,
          share_count: local_message.share_count || 0,
          reply_count: reply_count
        })
      end
    end
  rescue
    error in Postgrex.Error ->
      if unique_activitypub_violation?(error) do
        case resolve_local_message_for_post(local_message, nil) do
          %{id: resolved_id} = resolved_message when resolved_id != message_id ->
            persist_loaded_reply_count(resolved_message, reply_count)

          _ ->
            :ok
        end
      else
        reraise error, __STACKTRACE__
      end
  end

  defp persist_loaded_reply_count(_, _), do: :ok

  defp apply_local_reply_count_to_post(post, reply_count) when is_map(post) do
    post
    |> Map.put("reply_count", reply_count)
    |> Map.put("repliesCount", reply_count)
    |> Map.put("replies", Counts.put_collection_total(Map.get(post, "replies"), reply_count))
    |> Map.put("comments", Counts.put_collection_total(Map.get(post, "comments"), reply_count))
  end

  defp apply_local_reply_count_to_post(post, _reply_count), do: post

  defp loaded_reply_count(replies) when is_list(replies) do
    Enum.reduce(replies, 0, fn
      %{children: children} = _node, acc when is_list(children) ->
        acc + 1 + loaded_reply_count(children)

      _reply, acc ->
        acc + 1
    end)
  end

  defp loaded_reply_count(_), do: 0

  defp maybe_schedule_remote_poll_refresh(
         %{id: message_id, federated: true, post_type: "poll"} = message
       ) do
    if Ecto.assoc_loaded?(message.poll) && message.poll do
      send(self(), {:refresh_remote_poll, message_id})
    end
  end

  defp maybe_schedule_remote_poll_refresh(_), do: :ok

  @impl true
  def handle_event("toggle_reply_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reply_form, !socket.assigns.show_reply_form)
     |> assign(:replying_to_comment_id, nil)
     |> assign(:comment_reply_content, "")}
  end

  def handle_event("navigate_to_embedded_post", %{"id" => id}, socket) do
    navigate_id = Navigation.normalize_post_id(socket, id)
    {:noreply, ElektrineWeb.PostNavigation.navigate(socket, navigate_id)}
  end

  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket)
      when is_binary(url) and url != "" and url != "#" do
    ElektrineWeb.SafeLiveNavigation.noreply(socket, url)
  end

  def handle_event("navigate_to_embedded_post", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("navigate_to_post", %{"post_id" => post_id}, socket) do
    {:noreply,
     ElektrineWeb.PostNavigation.navigate(socket, Navigation.post_path(socket, post_id))}
  end

  def handle_event("navigate_to_post", %{"id" => id}, socket) do
    {:noreply, ElektrineWeb.PostNavigation.navigate(socket, Navigation.post_path(socket, id))}
  end

  def handle_event("navigate_to_post", %{"message_id" => message_id}, socket) do
    {:noreply,
     ElektrineWeb.PostNavigation.navigate(socket, Navigation.post_path(socket, message_id))}
  end

  def handle_event("navigate_to_remote_post", %{"id" => id, "url" => url}, socket)
      when is_binary(url) and url != "" do
    path =
      case Navigation.parse_local_message_id(Navigation.decode_post_ref(id)) do
        {:ok, local_id} -> Paths.remote_post_path(local_id)
        :error -> Paths.post_path_or_external(url)
      end

    {:noreply, ElektrineWeb.PostNavigation.navigate(socket, path)}
  end

  def handle_event("navigate_to_remote_post", %{"url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, ElektrineWeb.PostNavigation.navigate(socket, url)}
  end

  def handle_event("navigate_to_remote_post", %{"id" => id}, socket) do
    {:noreply, Navigation.navigate_to_remote_post_ref(socket, id)}
  end

  def handle_event("navigate_to_remote_post", %{"post_id" => post_id}, socket) do
    {:noreply, Navigation.navigate_to_remote_post_ref(socket, post_id)}
  end

  def handle_event("navigate_to_remote_post", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_external_link", %{"url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, redirect_to_external_url(socket, url)}
  end

  def handle_event("open_external_link", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("navigate_to_profile", %{"handle" => handle}, socket)
      when is_binary(handle) and handle != "" do
    ElektrineWeb.ProfileNavigation.navigate(socket, %{"handle" => handle})
  end

  def handle_event("navigate_to_profile", %{"username" => username}, socket)
      when is_binary(username) and username != "" do
    ElektrineWeb.ProfileNavigation.navigate(socket, %{"username" => username})
  end

  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_comment_reply", %{"comment_id" => comment_id}, socket) do
    current = socket.assigns.replying_to_comment_id
    new_id = if current == comment_id, do: nil, else: comment_id

    {:noreply,
     socket
     |> assign(:show_reply_form, false)
     |> assign(:replying_to_comment_id, new_id)
     |> assign(:comment_reply_content, "")}
  end

  def handle_event("update_comment_reply_content", %{"value" => content}, socket) do
    {:noreply, assign(socket, :comment_reply_content, content)}
  end

  def handle_event("submit_comment_reply", %{"content" => content}, socket) do
    if AccessPolicy.current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to reply")}
    else
      if Elektrine.Strings.present?(content) do
        user = socket.assigns.current_user
        comment_id = socket.assigns.replying_to_comment_id

        # Resolve local comments directly and federated comments via ActivityPub fetch/store.
        case SurfaceHelpers.resolve_comment_target_message(
               comment_id,
               socket.assigns.replies,
               socket.assigns.reply_ancestors
             ) do
          {:ok, message} ->
            # Create reply to the comment
            case Elektrine.Social.create_timeline_post(
                   user.id,
                   content,
                   visibility: "public",
                   reply_to_id: message.id
                 ) do
              {:ok, reply} ->
                # Build optimistic reply in AP format for immediate display
                base_url = ElektrineWeb.Endpoint.url()

                parent_reply_ref =
                  message.activitypub_id || message.activitypub_url ||
                    "#{base_url}/posts/#{message.id}"

                new_reply_ap = %{
                  "id" => reply.activitypub_id || "#{base_url}/messages/#{reply.id}",
                  "type" => "Note",
                  "attributedTo" => "#{base_url}/users/#{user.username}",
                  "content" => content,
                  "published" => NaiveDateTime.to_iso8601(reply.inserted_at) <> "Z",
                  "inReplyTo" => parent_reply_ref,
                  "likes" => %{"totalItems" => 0},
                  "shares" => %{"totalItems" => 0},
                  "_local" => true,
                  "_local_user" => user,
                  "_local_message_id" => reply.id,
                  "_local_like_count" => 0,
                  "_local_share_count" => 0
                }

                # Add new reply to existing replies
                updated_replies =
                  prepare_replies_for_render(socket, socket.assigns.replies ++ [new_reply_ap])

                {threaded_replies, thread_reply_actors} =
                  build_threaded_replies_with_actor_cache(
                    updated_replies,
                    socket.assigns.post["id"],
                    socket.assigns.comment_sort
                  )

                {:noreply,
                 socket
                 |> assign(:replies, updated_replies)
                 |> assign(
                   :quick_reply_recent_replies,
                   SurfaceHelpers.recent_replies_for_preview(
                     updated_replies,
                     socket.assigns.post["id"]
                   )
                 )
                 |> assign(:threaded_replies, threaded_replies)
                 |> assign(:thread_reply_actors, thread_reply_actors)
                 |> assign(:replying_to_comment_id, nil)
                 |> assign(:comment_reply_content, "")
                 |> put_flash(:info, "Reply posted!")}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to post reply")}
            end

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to process comment")}
        end
      else
        {:noreply, put_flash(socket, :error, "Reply cannot be empty")}
      end
    end
  end

  def handle_event("update_reply_content", %{"value" => content}, socket) do
    {:noreply, assign(socket, :reply_content, content)}
  end

  def handle_event("update_reply_content", %{"content" => content}, socket) do
    {:noreply, assign(socket, :reply_content, content)}
  end

  def handle_event("submit_reply", %{"content" => content}, socket) do
    if AccessPolicy.current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to reply")}
    else
      if Elektrine.Strings.present?(content) do
        user = socket.assigns.current_user
        post = socket.assigns.post

        if socket.assigns.is_local_post && socket.assigns.local_message do
          local_message = socket.assigns.local_message
          parent_id = local_message.activitypub_id || post["id"]

          case Elektrine.Social.create_timeline_post(
                 user.id,
                 content,
                 visibility: "public",
                 reply_to_id: local_message.id
               ) do
            {:ok, reply} ->
              base_url = ElektrineWeb.Endpoint.url()

              new_reply_ap = %{
                "id" => reply.activitypub_id || "#{base_url}/messages/#{reply.id}",
                "type" => "Note",
                "attributedTo" => "#{base_url}/users/#{user.username}",
                "content" => content,
                "published" => NaiveDateTime.to_iso8601(reply.inserted_at) <> "Z",
                "inReplyTo" => parent_id,
                "likes" => %{"totalItems" => 0},
                "shares" => %{"totalItems" => 0},
                "_local" => true,
                "_local_user" => user,
                "_local_message_id" => reply.id,
                "_local_like_count" => 0,
                "_local_share_count" => 0
              }

              updated_replies =
                prepare_replies_for_render(socket, socket.assigns.replies ++ [new_reply_ap])

              {threaded_replies, thread_reply_actors} =
                build_threaded_replies_with_actor_cache(
                  updated_replies,
                  post["id"],
                  socket.assigns.comment_sort
                )

              updated_local_message = %{
                local_message
                | reply_count: max((local_message.reply_count || 0) + 1, length(updated_replies))
              }

              {:noreply,
               socket
               |> assign(:replies, updated_replies)
               |> assign(
                 :quick_reply_recent_replies,
                 SurfaceHelpers.recent_replies_for_preview(updated_replies, post["id"])
               )
               |> assign(:threaded_replies, threaded_replies)
               |> assign(:thread_reply_actors, thread_reply_actors)
               |> assign(:local_message, updated_local_message)
               |> assign(:show_reply_form, false)
               |> assign(:reply_content, "")
               |> put_flash(:info, "Reply posted!")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to post reply")}
          end
        else
          activitypub_id = post["id"]

          # Get or store the post locally first
          case get_or_store_remote_post(activitypub_id, socket.assigns.remote_actor.uri) do
            {:ok, message} ->
              # Create reply
              case Elektrine.Social.create_timeline_post(
                     user.id,
                     content,
                     visibility: "public",
                     reply_to_id: message.id
                   ) do
                {:ok, reply} ->
                  # Build optimistic reply in AP format for immediate display
                  base_url = ElektrineWeb.Endpoint.url()

                  new_reply_ap = %{
                    "id" => reply.activitypub_id || "#{base_url}/messages/#{reply.id}",
                    "type" => "Note",
                    "attributedTo" => "#{base_url}/users/#{user.username}",
                    "content" => content,
                    "published" => NaiveDateTime.to_iso8601(reply.inserted_at) <> "Z",
                    "inReplyTo" => activitypub_id,
                    "likes" => %{"totalItems" => 0},
                    "shares" => %{"totalItems" => 0},
                    "_local" => true,
                    "_local_user" => user,
                    "_local_message_id" => reply.id,
                    "_local_like_count" => 0,
                    "_local_share_count" => 0
                  }

                  # Add new reply to existing replies
                  updated_replies =
                    prepare_replies_for_render(socket, socket.assigns.replies ++ [new_reply_ap])

                  {threaded_replies, thread_reply_actors} =
                    build_threaded_replies_with_actor_cache(
                      updated_replies,
                      socket.assigns.post["id"],
                      socket.assigns.comment_sort
                    )

                  {:noreply,
                   socket
                   |> assign(:replies, updated_replies)
                   |> assign(
                     :quick_reply_recent_replies,
                     SurfaceHelpers.recent_replies_for_preview(
                       updated_replies,
                       socket.assigns.post["id"]
                     )
                   )
                   |> assign(:threaded_replies, threaded_replies)
                   |> assign(:thread_reply_actors, thread_reply_actors)
                   |> assign(:show_reply_form, false)
                   |> assign(:reply_content, "")
                   |> put_flash(
                     :info,
                     "Reply posted! It will be federated to #{socket.assigns.remote_actor.domain}"
                   )}

                {:error, _} ->
                  {:noreply, put_flash(socket, :error, "Failed to post reply")}
              end

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to process remote post")}
          end
        end
      else
        {:noreply, put_flash(socket, :error, "Reply cannot be empty")}
      end
    end
  end

  def handle_event("like_post", %{"message_id" => message_id}, socket) do
    if main_detail_message_id?(socket, message_id) do
      cond do
        AccessPolicy.current_user_missing?(socket) ->
          {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}

        main_detail_liked?(socket) ->
          {:noreply, socket}

        true ->
          case Social.like_post(socket.assigns.current_user.id, socket.assigns.local_message.id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> set_main_detail_liked(true)
               |> refresh_main_detail_message()
               |> put_flash(:info, "Liked")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to like post")}
          end
      end
    else
      Interactions.like_message(socket, message_id,
        on_refresh: &maybe_assign_displayed_local_message/2,
        on_like_delta: &maybe_adjust_like_surface_count/3
      )
    end
  end

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    Interactions.like_post(socket, post_id, on_refresh: &maybe_assign_displayed_local_message/2)
  end

  def handle_event("unlike_post", %{"message_id" => message_id}, socket) do
    if main_detail_message_id?(socket, message_id) do
      if main_detail_liked?(socket) do
        case Social.unlike_post(socket.assigns.current_user.id, socket.assigns.local_message.id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> set_main_detail_liked(false)
             |> refresh_main_detail_message()
             |> put_flash(:info, "Unliked")}

          {:error, _} ->
            {:noreply, socket}
        end
      else
        {:noreply, socket}
      end
    else
      Interactions.unlike_message(socket, message_id,
        on_refresh: &maybe_assign_displayed_local_message/2,
        on_like_delta: &maybe_adjust_like_surface_count/3
      )
    end
  end

  def handle_event("unlike_post", %{"post_id" => post_id}, socket) do
    Interactions.unlike_post(socket, post_id, on_refresh: &maybe_assign_displayed_local_message/2)
  end

  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    if AccessPolicy.current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    else
      # Check current like state
      current_state = socket.assigns.post_interactions[post_id] || %{liked: false}
      is_liked = Map.get(current_state, :liked, false)

      if is_liked do
        # Unlike - delegate to unlike_post
        handle_event("unlike_post", %{"post_id" => post_id}, socket)
      else
        # Like - delegate to like_post
        handle_event("like_post", %{"post_id" => post_id}, socket)
      end
    end
  end

  def handle_event("boost_post", %{"message_id" => message_id}, socket) do
    if main_detail_message_id?(socket, message_id) do
      cond do
        AccessPolicy.current_user_missing?(socket) ->
          {:noreply, put_flash(socket, :error, "You must be signed in to boost posts")}

        main_detail_boosted?(socket) ->
          {:noreply, socket}

        true ->
          case Social.boost_post(socket.assigns.current_user.id, socket.assigns.local_message.id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> set_main_detail_boosted(true)
               |> refresh_main_detail_message()
               |> put_flash(:info, "Post boosted to your timeline!")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to boost post")}
          end
      end
    else
      Interactions.boost_message(socket, message_id,
        on_refresh: &maybe_assign_displayed_local_message/2,
        on_boost_delta: &maybe_adjust_boost_surface_count/3
      )
    end
  end

  def handle_event("boost_post", %{"post_id" => post_id}, socket) do
    Interactions.boost_post(socket, post_id,
      on_refresh: &maybe_assign_displayed_local_message/2,
      on_boost_delta: &maybe_adjust_boost_surface_count/3
    )
  end

  def handle_event("unboost_post", %{"message_id" => message_id}, socket) do
    if main_detail_message_id?(socket, message_id) do
      if main_detail_boosted?(socket) do
        case Social.unboost_post(socket.assigns.current_user.id, socket.assigns.local_message.id) do
          {:ok, _} ->
            {:noreply, socket |> set_main_detail_boosted(false) |> refresh_main_detail_message()}

          {:error, _} ->
            {:noreply, socket}
        end
      else
        {:noreply, socket}
      end
    else
      Interactions.unboost_message(socket, message_id,
        on_refresh: &maybe_assign_displayed_local_message/2,
        on_boost_delta: &maybe_adjust_boost_surface_count/3
      )
    end
  end

  def handle_event("unboost_post", %{"post_id" => post_id}, socket) do
    Interactions.unboost_post(socket, post_id,
      on_refresh: &maybe_assign_displayed_local_message/2,
      on_boost_delta: &maybe_adjust_boost_surface_count/3
    )
  end

  # Save/bookmark post handlers
  def handle_event("save_post", %{"post_id" => post_id}, socket) do
    Interactions.save_message(socket, post_id)
  end

  def handle_event("save_post", %{"message_id" => message_id}, socket) do
    if main_detail_message_id?(socket, message_id) do
      cond do
        AccessPolicy.current_user_missing?(socket) ->
          {:noreply, put_flash(socket, :error, "You must be signed in to save posts")}

        main_detail_saved?(socket) ->
          {:noreply, socket}

        true ->
          updated_socket = set_main_detail_saved(socket, true)

          case Social.save_post(socket.assigns.current_user.id, socket.assigns.local_message.id) do
            {:ok, _} -> {:noreply, put_flash(updated_socket, :info, "Saved")}
            {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to save")}
          end
      end
    else
      Interactions.save_message(socket, message_id)
    end
  end

  def handle_event("unsave_post", %{"post_id" => post_id}, socket) do
    Interactions.unsave_message(socket, post_id)
  end

  def handle_event("unsave_post", %{"message_id" => message_id}, socket) do
    if main_detail_message_id?(socket, message_id) do
      if main_detail_saved?(socket) do
        updated_socket = set_main_detail_saved(socket, false)

        case Social.unsave_post(socket.assigns.current_user.id, socket.assigns.local_message.id) do
          {:ok, _} -> {:noreply, put_flash(updated_socket, :info, "Removed from saved")}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to unsave")}
        end
      else
        {:noreply, socket}
      end
    else
      Interactions.unsave_message(socket, message_id)
    end
  end

  def handle_event("upvote_post", %{"post_id" => post_id}, socket) do
    Interactions.vote_remote_target(socket, post_id, "up",
      target_label: "post",
      on_refresh: &maybe_assign_displayed_local_message/2
    )
  end

  def handle_event("upvote_post", %{"message_id" => message_id}, socket) do
    handle_event("upvote_post", %{"post_id" => message_id}, socket)
  end

  def handle_event("unupvote_post", %{"post_id" => post_id}, socket) do
    Interactions.vote_remote_target(socket, post_id, "up",
      target_label: "post",
      on_refresh: &maybe_assign_displayed_local_message/2
    )
  end

  def handle_event("unupvote_post", %{"message_id" => message_id}, socket) do
    handle_event("unupvote_post", %{"post_id" => message_id}, socket)
  end

  def handle_event("downvote_post", %{"post_id" => post_id}, socket) do
    Interactions.vote_remote_target(socket, post_id, "down",
      target_label: "post",
      on_refresh: &maybe_assign_displayed_local_message/2
    )
  end

  def handle_event("downvote_post", %{"message_id" => message_id}, socket) do
    handle_event("downvote_post", %{"post_id" => message_id}, socket)
  end

  def handle_event("undownvote_post", %{"post_id" => post_id}, socket) do
    Interactions.vote_remote_target(socket, post_id, "down",
      target_label: "post",
      on_refresh: &maybe_assign_displayed_local_message/2
    )
  end

  def handle_event("undownvote_post", %{"message_id" => message_id}, socket) do
    handle_event("undownvote_post", %{"post_id" => message_id}, socket)
  end

  # Reddit-style voting for Lemmy community posts
  def handle_event("vote_post", %{"type" => vote_type}, socket) do
    Interactions.vote_remote_target(socket, socket.assigns.post["id"], vote_type,
      target_label: "post"
    )
  end

  # Reddit-style voting for Lemmy comments
  def handle_event(
        "vote_comment",
        %{"comment_id" => comment_id, "type" => vote_type} = params,
        socket
      ) do
    target_id =
      usable_interaction_id(comment_id) || usable_interaction_id(params["activitypub_id"])

    Interactions.vote_remote_target(socket, target_id, vote_type,
      target_label: "comment",
      on_refresh: &maybe_assign_reply_vote_counts/2
    )
  end

  def handle_event("react_to_post", %{"post_id" => post_id, "emoji" => emoji}, socket) do
    Interactions.react_remote_post(socket, post_id, emoji)
  end

  def handle_event("react_to_post", %{"message_id" => message_id, "emoji" => emoji}, socket) do
    Interactions.react_message(socket, message_id, emoji)
  end

  def handle_event(
        "open_image_modal",
        %{"url" => url, "images" => images_json, "index" => index},
        socket
      ) do
    images =
      case Jason.decode(images_json) do
        {:ok, decoded} when is_list(decoded) -> decoded
        _ -> []
      end

    modal_image_index =
      case Integer.parse(to_string(index)) do
        {parsed, _} when parsed >= 0 -> min(parsed, max(length(images) - 1, 0))
        _ -> 0
      end

    modal_post = build_modal_post(socket)

    {:noreply,
     socket
     |> assign(:show_image_modal, true)
     |> assign(:modal_image_url, url)
     |> assign(:modal_images, images)
     |> assign(:modal_image_index, modal_image_index)
     |> assign(:modal_post, modal_post)}
  end

  # close_image_modal / next_image / prev_image only touch the canonical modal-state
  # assigns, so delegate to the shared image-modal handlers.
  def handle_event(event, params, socket)
      when event in ["close_image_modal", "next_image", "prev_image"] do
    ElektrineSocialWeb.TimelineLive.Operations.ImageOperations.handle_event(event, params, socket)
  end

  def handle_event("sort_comments", %{"sort" => sort}, socket) do
    {threaded_replies, thread_reply_actors} =
      build_threaded_replies_with_actor_cache(
        prepare_replies_for_render(socket, socket.assigns.replies),
        socket.assigns.post["id"],
        sort
      )

    {:noreply,
     socket
     |> assign(:comment_sort, sort)
     |> assign(
       :replies,
       prepare_replies_for_render(socket, socket.assigns.replies)
     )
     |> assign(:threaded_replies, threaded_replies)
     |> assign(:thread_reply_actors, thread_reply_actors)}
  end

  def handle_event("load_comments", _params, socket) do
    if socket.assigns.post do
      send(self(), {:load_replies, socket.assigns.post, force_sync: true})
      send(self(), {:load_platform_counts, field_value(socket.assigns.post, ["id", :id])})
      {:noreply, assign(socket, :replies_loading, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("refresh_comments", _params, socket) do
    if socket.assigns.post do
      send(self(), {:load_replies, socket.assigns.post, force_sync: true})
      send(self(), {:load_platform_counts, field_value(socket.assigns.post, ["id", :id])})
      {:noreply, assign(socket, :replies_loading, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_follow_community", _params, socket) do
    require Logger

    if AccessPolicy.current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to follow communities")}
    else
      community_actor = socket.assigns.community_actor

      if community_actor do
        if socket.assigns.is_following_community || socket.assigns.is_pending_community do
          # Unfollow or cancel pending request
          case Elektrine.Profiles.unfollow_remote_actor(
                 socket.assigns.current_user.id,
                 community_actor.id
               ) do
            {:ok, :unfollowed} ->
              {:noreply,
               socket
               |> assign(:is_following_community, false)
               |> assign(:is_pending_community, false)
               |> put_flash(:info, "Left community")}

            {:error, reason} ->
              Logger.warning("Failed to leave community: #{inspect(reason)}")

              {:noreply,
               socket
               |> assign(:is_following_community, false)
               |> assign(:is_pending_community, false)
               |> put_flash(:error, "Failed to leave community")}
          end
        else
          # Follow
          Logger.info(
            "Attempting to join community: #{community_actor.username}@#{community_actor.domain}"
          )

          case Elektrine.Profiles.follow_remote_actor(
                 socket.assigns.current_user.id,
                 community_actor.id
               ) do
            {:ok, follow} ->
              # Check if follow is pending (waiting for remote Accept)
              if follow.pending do
                {:noreply,
                 socket
                 |> assign(:is_pending_community, true)
                 |> put_flash(:info, "Join request sent! Waiting for community approval.")}
              else
                {:noreply,
                 socket
                 |> assign(:is_following_community, true)
                 |> assign(:is_pending_community, false)
                 |> put_flash(:info, "Joined community!")}
              end

            {:error, :already_following} ->
              {:noreply,
               socket
               |> assign(:is_following_community, true)
               |> put_flash(:info, "You're already a member of this community")}

            {:error, reason} ->
              Logger.warning("Failed to join community: #{inspect(reason)}")
              {:noreply, put_flash(socket, :error, "Failed to join community")}
          end
        end
      else
        Logger.warning("No community_actor found for toggle_follow_community")
        {:noreply, put_flash(socket, :error, "Community not found")}
      end
    end
  end

  def handle_event("toggle_follow_author", _params, socket) do
    if AccessPolicy.current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to follow users")}
    else
      remote_actor = socket.assigns[:remote_actor]

      if remote_actor do
        if socket.assigns.is_following_author || socket.assigns.is_pending_author do
          case Elektrine.Profiles.unfollow_remote_actor(
                 socket.assigns.current_user.id,
                 remote_actor.id
               ) do
            {:ok, :unfollowed} ->
              {:noreply,
               socket
               |> assign(:is_following_author, false)
               |> assign(:is_pending_author, false)
               |> assign_remote_author_follow_maps(remote_actor, false, false)
               |> put_flash(:info, "Unfollowed")}

            {:error, _reason} ->
              {:noreply,
               socket
               |> assign(:is_following_author, false)
               |> assign(:is_pending_author, false)
               |> put_flash(:error, "Failed to unfollow")}
          end
        else
          case Elektrine.Profiles.follow_remote_actor(
                 socket.assigns.current_user.id,
                 remote_actor.id
               ) do
            {:ok, follow} ->
              if follow.pending do
                {:noreply,
                 socket
                 |> assign(:is_following_author, false)
                 |> assign(:is_pending_author, true)
                 |> assign_remote_author_follow_maps(remote_actor, false, true)
                 |> put_flash(:info, "Follow request sent!")}
              else
                {:noreply,
                 socket
                 |> assign(:is_following_author, true)
                 |> assign(:is_pending_author, false)
                 |> assign_remote_author_follow_maps(remote_actor, true, false)
                 |> put_flash(:info, "Following!")}
              end

            {:error, :already_following} ->
              {:noreply,
               socket
               |> assign(:is_following_author, true)
               |> assign(:is_pending_author, false)
               |> assign_remote_author_follow_maps(remote_actor, true, false)
               |> put_flash(:info, "Already following")}

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, "Failed to follow")}
          end
        end
      else
        {:noreply, put_flash(socket, :error, "Author not found")}
      end
    end
  end

  def handle_event("toggle_follow", %{"user_id" => user_id}, socket) do
    if AccessPolicy.current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to follow users")}
    else
      case Integer.parse(to_string(user_id)) do
        {user_id, ""} ->
          current_user_id = socket.assigns.current_user.id
          currently_following = Map.get(socket.assigns.user_follows, {:local, user_id}, false)

          if currently_following do
            case Profiles.unfollow_user(current_user_id, user_id) do
              {:ok, :unfollowed} ->
                {:noreply,
                 update(socket, :user_follows, &Map.put(&1, {:local, user_id}, false))
                 |> put_flash(:info, "Unfollowed user.")}

              {:ok, :not_following} ->
                {:noreply,
                 update(socket, :user_follows, &Map.put(&1, {:local, user_id}, false))
                 |> put_flash(:info, "Unfollowed user.")}
            end
          else
            case Profiles.follow_user(current_user_id, user_id) do
              {:ok, _follow} ->
                {:noreply,
                 update(socket, :user_follows, &Map.put(&1, {:local, user_id}, true))
                 |> put_flash(:info, "Now following user.")}

              {:error, _reason} ->
                {:noreply,
                 put_flash(
                   socket,
                   :error,
                   "Couldn't follow this user right now. Please try again."
                 )}
            end
          end

        _ ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("toggle_follow_remote", %{"remote_actor_id" => remote_actor_id}, socket) do
    if AccessPolicy.current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to follow users")}
    else
      case Integer.parse(to_string(remote_actor_id)) do
        {actor_id, ""} ->
          is_following = Map.get(socket.assigns.user_follows, {:remote, actor_id}, false)
          is_pending = Map.get(socket.assigns.pending_follows, {:remote, actor_id}, false)

          if is_following || is_pending do
            case Elektrine.Profiles.unfollow_remote_actor(
                   socket.assigns.current_user.id,
                   actor_id
                 ) do
              {:ok, _} ->
                {:noreply,
                 socket
                 |> update(:user_follows, &Map.put(&1, {:remote, actor_id}, false))
                 |> update(:pending_follows, &Map.put(&1, {:remote, actor_id}, false))
                 |> update(:remote_follow_overrides, &Map.put(&1, actor_id, "none"))
                 |> push_event("remote_follow_state_changed", %{
                   remote_actor_id: actor_id,
                   state: "none"
                 })
                 |> maybe_assign_author_follow_state(actor_id, false, false)
                 |> put_flash(:info, "Unfollowed")}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, "Failed to unfollow")}
            end
          else
            case Elektrine.Profiles.follow_remote_actor(socket.assigns.current_user.id, actor_id) do
              {:ok, follow} ->
                following = !follow.pending
                pending = follow.pending

                {:noreply,
                 socket
                 |> update(:user_follows, &Map.put(&1, {:remote, actor_id}, following))
                 |> update(:pending_follows, &Map.put(&1, {:remote, actor_id}, pending))
                 |> update(
                   :remote_follow_overrides,
                   &Map.put(&1, actor_id, if(pending, do: "pending", else: "following"))
                 )
                 |> push_event("remote_follow_state_changed", %{
                   remote_actor_id: actor_id,
                   state: if(pending, do: "pending", else: "following")
                 })
                 |> maybe_assign_author_follow_state(actor_id, following, pending)
                 |> put_flash(:info, if(pending, do: "Follow request sent!", else: "Following!"))}

              {:error, :already_following} ->
                {:noreply,
                 socket
                 |> update(:user_follows, &Map.put(&1, {:remote, actor_id}, true))
                 |> update(:pending_follows, &Map.put(&1, {:remote, actor_id}, false))
                 |> update(:remote_follow_overrides, &Map.put(&1, actor_id, "following"))
                 |> push_event("remote_follow_state_changed", %{
                   remote_actor_id: actor_id,
                   state: "following"
                 })
                 |> maybe_assign_author_follow_state(actor_id, true, false)
                 |> put_flash(:info, "Already following")}

              {:error, _reason} ->
                {:noreply, put_flash(socket, :error, "Failed to follow")}
            end
          end

        _ ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("vote_poll", params, socket) do
    if AccessPolicy.current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    else
      poll_id = params["poll_id"] || params["poll-id"]
      option_id = params["option_id"] || params["option-id"]

      with {poll_id, _} <- Integer.parse(to_string(poll_id)),
           {option_id, _} <- Integer.parse(to_string(option_id)) do
        case Social.vote_on_poll(poll_id, option_id, socket.assigns.current_user.id) do
          {:ok, _vote} ->
            poll = Elektrine.Repo.get!(Elektrine.Social.Poll, poll_id)

            refreshed_message =
              poll.message_id
              |> Messaging.get_message()
              |> preload_cached_message_associations()

            if refreshed_message && refreshed_message.federated do
              maybe_schedule_remote_poll_refresh(refreshed_message)
            end

            {:noreply,
             socket
             |> assign(:local_message, refreshed_message)
             |> assign(
               :post,
               Polls.merge_local_poll_data(socket.assigns[:post], refreshed_message)
             )
             |> put_flash(:info, "Vote recorded")}

          {:error, :poll_closed} ->
            {:noreply, put_flash(socket, :error, "This poll has closed")}

          {:error, :invalid_option} ->
            {:noreply, put_flash(socket, :error, "Invalid poll option")}

          {:error, :self_vote} ->
            {:noreply, put_flash(socket, :error, "You cannot vote on your own poll")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to vote")}
        end
      else
        _ -> {:noreply, put_flash(socket, :error, "Invalid poll vote")}
      end
    end
  end

  def handle_event("vote_remote_poll", %{"option_name" => option_name} = params, socket) do
    if AccessPolicy.current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    else
      post = socket.assigns.post
      remote_actor = socket.assigns.remote_actor
      poll_id = params["poll_id"] || post["id"]

      option_id =
        case params["option_id"] do
          value when is_binary(value) ->
            case Integer.parse(value) do
              {parsed, ""} -> parsed
              _ -> nil
            end

          value when is_integer(value) ->
            value

          _ ->
            nil
        end

      # send_poll_vote already queues durable outbound delivery internally.
      Elektrine.ActivityPub.Outbox.send_poll_vote(
        socket.assigns.current_user,
        poll_id,
        option_name,
        remote_actor
      )

      {:noreply,
       socket
       |> assign(:pending_remote_poll_vote, %{
         option_id: option_id,
         option_name: option_name,
         domain: remote_actor.domain
       })
       |> put_flash(:info, "Vote sent to #{remote_actor.domain}")}
    end
  end

  # Catch-all for unhandled events (e.g., connection_changed from JS)
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  defp maybe_apply_lemmy_comment_counts(socket, counts) when is_map(counts) and counts != %{} do
    replies =
      prepare_replies_for_render(
        assign(socket, :lemmy_comment_counts, counts),
        socket.assigns.replies || []
      )

    {threaded_replies, thread_reply_actors} =
      build_threaded_replies_with_actor_cache(
        replies,
        field_value(socket.assigns[:post], ["id", :id]),
        socket.assigns.comment_sort
      )

    socket
    |> assign(:replies, replies)
    |> assign(
      :quick_reply_recent_replies,
      SurfaceHelpers.recent_replies_for_preview(
        replies,
        field_value(socket.assigns[:post], ["id", :id])
      )
    )
    |> assign(:threaded_replies, threaded_replies)
    |> assign(:thread_reply_actors, thread_reply_actors)
  end

  defp maybe_apply_lemmy_comment_counts(socket, _), do: socket

  defp maybe_queue_reply_counts_load(socket) do
    if reply_count_lookup_posts(socket.assigns[:replies] || []) == [] do
      socket
    else
      send(self(), :load_reply_counts)
      socket
    end
  end

  defp reply_count_lookup_posts(replies) when is_list(replies) do
    replies
    |> Enum.map(&reply_count_lookup_post/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn post ->
      {Map.get(post, :activitypub_id), Map.get(post, :activitypub_url)}
    end)
  end

  defp reply_count_lookup_posts(_), do: []

  defp reply_count_lookup_post(%{} = reply) do
    activitypub_id =
      first_platform_count_ref([
        reply_surface_ref(reply),
        field_value(reply, ["activitypub_id", :activitypub_id])
      ])

    activitypub_url =
      first_platform_count_ref([
        field_value(reply, ["url", :url]),
        field_value(reply, ["activitypub_url", :activitypub_url])
      ])

    if activitypub_id || activitypub_url do
      %{activitypub_id: activitypub_id, activitypub_url: activitypub_url}
    end
  end

  defp reply_count_lookup_post(_), do: nil

  defp apply_reply_platform_counts(socket, counts_by_reply)
       when is_map(counts_by_reply) and counts_by_reply != %{} do
    replies =
      socket.assigns[:replies]
      |> Kernel.||([])
      |> Enum.map(&apply_reply_platform_count(&1, counts_by_reply))

    replies = prepare_replies_for_render(socket, replies)

    {threaded_replies, thread_reply_actors} =
      build_threaded_replies_with_actor_cache(
        replies,
        field_value(socket.assigns[:post], ["id", :id]),
        socket.assigns.comment_sort
      )

    socket
    |> assign(:replies, replies)
    |> assign(
      :quick_reply_recent_replies,
      SurfaceHelpers.recent_replies_for_preview(
        replies,
        field_value(socket.assigns[:post], ["id", :id])
      )
    )
    |> assign(:threaded_replies, threaded_replies)
    |> assign(:thread_reply_actors, thread_reply_actors)
  end

  defp apply_reply_platform_counts(socket, _), do: socket

  defp apply_reply_platform_count(%{} = reply, counts_by_reply) do
    case reply_platform_counts(reply, counts_by_reply) do
      %{} = mastodon_counts ->
        counts = reply_counts_from_mastodon(mastodon_counts)
        maybe_sync_reply_platform_counts(reply, counts, mastodon_counts)

        reply
        |> maybe_put_collection_count("likes", Map.get(counts, :like_count))
        |> maybe_put_collection_count("shares", Map.get(counts, :share_count))
        |> maybe_put_collection_count("replies", Map.get(counts, :reply_count))
        |> maybe_put_reply_count("_local_like_count", Map.get(counts, :like_count))
        |> maybe_put_reply_count("_local_share_count", Map.get(counts, :share_count))
        |> maybe_put_reply_count("_local_reply_count", Map.get(counts, :reply_count))

      _ ->
        reply
    end
  end

  defp apply_reply_platform_count(reply, _counts_by_reply), do: reply

  defp reply_platform_counts(reply, counts_by_reply) do
    reply
    |> reply_count_keys()
    |> Enum.find_value(&Map.get(counts_by_reply, &1))
  end

  defp reply_count_keys(reply) do
    [
      reply_surface_ref(reply),
      field_value(reply, ["url", :url]),
      field_value(reply, ["activitypub_url", :activitypub_url])
    ]
    |> Enum.map(&normalize_in_reply_to_ref/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp reply_counts_from_mastodon(counts) when is_map(counts) do
    %{
      like_count: nonnegative_integer(Map.get(counts, :favourites_count)),
      reply_count: nonnegative_integer(Map.get(counts, :replies_count)),
      share_count: nonnegative_integer(Map.get(counts, :reblogs_count)),
      quote_count: nonnegative_integer(Map.get(counts, :quotes_count))
    }
  end

  defp maybe_sync_reply_platform_counts(reply, counts, mastodon_counts) do
    with message_id when is_integer(message_id) <- reply_local_message_id(reply),
         %Elektrine.Social.Message{} = message <-
           Elektrine.Repo.get(Elektrine.Social.Message, message_id) do
      metadata = platform_metadata_from_result(mastodon_counts, nil, nil)
      sync_local_message_platform_counts(message, counts, metadata)
    end
  end

  defp maybe_put_collection_count(reply, _field, nil), do: reply

  defp maybe_put_collection_count(reply, field, count) when is_integer(count) do
    Map.put(reply, field, %{"totalItems" => max(count, 0)})
  end

  defp maybe_put_reply_count(reply, _field, nil), do: reply

  defp maybe_put_reply_count(reply, field, count) when is_integer(count) do
    Map.put(reply, field, max(count, 0))
  end

  defp nonnegative_integer(value) when is_integer(value), do: max(value, 0)
  defp nonnegative_integer(_), do: nil

  defp finalize_initial_comment_reveal(socket) do
    socket = assign(socket, :awaiting_initial_comment_counts, false)

    if socket.assigns[:pending_initial_comment_reveal] do
      socket
      |> assign(:replies_loading, false)
      |> assign(:replies_loaded, true)
      |> assign(:pending_initial_comment_reveal, false)
    else
      socket
    end
  end

  defp prepare_replies_for_render(socket, replies) when is_list(replies) do
    replies
    |> hydrate_replies_with_local_counts()
    |> enrich_replies_with_lemmy_counts(socket.assigns[:lemmy_comment_counts] || %{})
    |> enrich_replies_with_link_previews(reply_content_domain(socket))
  end

  defp prepare_replies_for_render(_, replies), do: replies

  defp hydrate_replies_with_local_counts(replies) when is_list(replies) do
    import Ecto.Query

    local_message_ids =
      replies
      |> Enum.map(&reply_local_message_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if local_message_ids == [] do
      replies
    else
      messages =
        Elektrine.Social.Message
        |> where([message], message.id in ^local_message_ids)
        |> Elektrine.Repo.all()

      messages_by_id = Map.new(messages, &{&1.id, &1})
      local_message_id_set = MapSet.new(local_message_ids)

      child_counts_by_parent_id =
        Enum.reduce(messages, %{}, fn
          %{reply_to_id: parent_id}, acc when is_integer(parent_id) ->
            if MapSet.member?(local_message_id_set, parent_id) do
              Map.update(acc, parent_id, 1, &(&1 + 1))
            else
              acc
            end

          _, acc ->
            acc
        end)

      Enum.map(
        replies,
        &hydrate_reply_with_local_counts(&1, messages_by_id, child_counts_by_parent_id)
      )
    end
  end

  defp hydrate_reply_with_local_counts(%{} = reply, messages_by_id, child_counts_by_parent_id) do
    case Map.get(messages_by_id, reply_local_message_id(reply)) do
      %Elektrine.Social.Message{} = message ->
        reply_count =
          max(message.reply_count || 0, Map.get(child_counts_by_parent_id, message.id, 0))

        reply
        |> Map.put("likes", %{"totalItems" => message.like_count || 0})
        |> Map.put("shares", %{"totalItems" => message.share_count || 0})
        |> Map.put("replies", %{"totalItems" => reply_count})
        |> Map.put("_local_like_count", SurfaceHelpers.local_vote_display_count(message))
        |> Map.put("_local_share_count", message.share_count || 0)
        |> Map.put("_local_reply_count", reply_count)

      _ ->
        reply
    end
  end

  defp hydrate_reply_with_local_counts(reply, _messages_by_id, _child_counts_by_parent_id),
    do: reply

  defp reply_local_message_id(reply) when is_map(reply) do
    case field_value(reply, ["_local_message_id", :_local_message_id]) do
      message_id when is_integer(message_id) ->
        message_id

      message_id when is_binary(message_id) ->
        case Integer.parse(String.trim(message_id)) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp reply_local_message_id(_), do: nil

  defp reply_surface_ref(reply) when is_map(reply) do
    reply["id"] || reply[:id] || reply["_local_activitypub_id"] || reply[:_local_activitypub_id]
  end

  defp enrich_replies_with_lemmy_counts(replies, counts)
       when is_list(replies) and is_map(counts) do
    Enum.map(replies, fn
      reply when is_map(reply) ->
        reply_id = reply_surface_ref(reply)

        count_data = if is_binary(reply_id), do: Map.get(counts, reply_id), else: nil

        if is_map(count_data) do
          lemmy_data =
            (reply["_lemmy"] || reply[:_lemmy] || %{})
            |> Map.merge(%{
              "upvotes" => count_data[:upvotes] || 0,
              "downvotes" => count_data[:downvotes] || 0,
              "score" => count_data[:score] || 0,
              "child_count" => count_data[:child_count] || 0
            })

          reply
          |> Map.put("_lemmy", lemmy_data)
          |> Map.put("likes", %{"totalItems" => count_data[:upvotes] || 0})
          |> Map.put("dislikes", %{"totalItems" => count_data[:downvotes] || 0})
        else
          reply
        end

      reply ->
        reply
    end)
  end

  defp enrich_replies_with_lemmy_counts(replies, _), do: replies

  defp enrich_replies_with_link_previews(replies, remote_actor_domain)
       when is_list(replies) do
    import Ecto.Query

    replies_with_urls =
      Enum.map(replies, fn
        reply when is_map(reply) ->
          submitted_url =
            field_value(reply, ["_submitted_url", :_submitted_url]) ||
              SubmittedLinks.detect_submitted_url(reply, nil, remote_actor_domain)

          reply
          |> Map.put("_submitted_url", submitted_url)
          |> Map.put(
            "_youtube_id",
            field_value(reply, ["_youtube_id", :_youtube_id]) ||
              SubmittedLinks.extract_youtube_id(submitted_url)
          )

        reply ->
          reply
      end)

    preview_urls =
      replies_with_urls
      |> Enum.map(&field_value(&1, ["_submitted_url", :_submitted_url]))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    previews_by_url =
      if preview_urls == [] do
        %{}
      else
        Elektrine.Social.LinkPreview
        |> where([preview], preview.url in ^preview_urls and preview.status == "success")
        |> Elektrine.Repo.all()
        |> Map.new(&{&1.url, &1})
      end

    Enum.map(replies_with_urls, fn
      %{} = reply ->
        submitted_url = field_value(reply, ["_submitted_url", :_submitted_url])

        preview_checked? =
          Map.get(reply, "_link_preview_checked") == true ||
            Map.get(reply, :_link_preview_checked) == true

        preview =
          if is_binary(submitted_url) do
            Map.get(previews_by_url, submitted_url)
          else
            field_value(reply, ["_link_preview", :_link_preview])
          end

        if is_nil(preview) and !preview_checked? do
          maybe_enqueue_reply_link_preview(submitted_url, reply)
        end

        reply
        |> Map.put("_link_preview", preview)
        |> Map.put("_link_preview_checked", true)

      reply ->
        reply
    end)
  end

  defp enrich_replies_with_link_previews(replies, _), do: replies

  defp maybe_enqueue_reply_link_preview(url, %{} = reply) when is_binary(url) do
    case field_value(reply, ["_local_message_id", :_local_message_id]) do
      message_id when is_integer(message_id) ->
        maybe_enqueue_submitted_link_preview(url, %{id: message_id})

      _ ->
        :ok
    end
  end

  defp maybe_enqueue_reply_link_preview(_, _), do: :ok

  defp reply_content_domain(socket) do
    case socket.assigns[:remote_actor] do
      %{domain: domain} when is_binary(domain) -> domain
      _ -> nil
    end
  end

  defp initial_community_stats(%{actor_type: "Group", metadata: metadata}) do
    metadata = metadata || %{}

    %{
      members: get_follower_count(metadata),
      posts: get_status_count(metadata)
    }
  end

  defp initial_community_stats(_), do: %{members: 0, posts: 0}

  defp resolved_community_stats(
         %{actor_type: "Group", id: actor_id} = community_actor,
         current_stats
       )
       when is_integer(actor_id) do
    merge_community_stats(
      merge_community_stats(current_stats, initial_community_stats(community_actor)),
      ElektrineSocial.RemoteUser.Metrics.cached_community_stats(actor_id)
    )
  end

  defp resolved_community_stats(community_actor, current_stats) do
    merge_community_stats(current_stats, initial_community_stats(community_actor))
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

  defp local_message_community_actor(%{
         conversation: %{remote_group_actor: %{actor_type: "Group"} = actor}
       }),
       do: actor

  defp local_message_community_actor(message) do
    case DiscussionSource.community_uri_from_local_message(message) do
      uri when is_binary(uri) -> ActivityPub.get_actor_by_uri(uri)
      _ -> nil
    end
  end

  defp remote_follow_state(%{id: user_id}, %{} = remote_actor) do
    if Elektrine.Profiles.following_remote_actor_by_identity?(user_id, remote_actor) do
      {true, false}
    else
      case Elektrine.Profiles.get_follow_to_remote_actor_by_identity(user_id, remote_actor) do
        %{pending: true} -> {false, true}
        _ -> {false, false}
      end
    end
  end

  defp remote_follow_state(_, _), do: {false, false}

  defp assign_remote_author_follow_maps(socket, %{id: actor_id}, is_following, is_pending) do
    socket
    |> assign(
      :user_follows,
      Map.put(socket.assigns[:user_follows] || %{}, {:remote, actor_id}, is_following)
    )
    |> assign(
      :pending_follows,
      Map.put(socket.assigns[:pending_follows] || %{}, {:remote, actor_id}, is_pending)
    )
    |> assign(
      :remote_follow_overrides,
      Map.put(
        socket.assigns[:remote_follow_overrides] || %{},
        actor_id,
        if(is_following, do: "following", else: if(is_pending, do: "pending", else: "none"))
      )
    )
  end

  defp assign_remote_author_follow_maps(socket, _remote_actor, _is_following, _is_pending),
    do: socket

  defp maybe_assign_author_follow_state(socket, actor_id, is_following, is_pending) do
    case socket.assigns[:remote_actor] do
      %{id: ^actor_id} ->
        socket
        |> assign(:is_following_author, is_following)
        |> assign(:is_pending_author, is_pending)

      _ ->
        socket
    end
  end

  # Helper functions - delegating to shared APHelpers module

  defp main_detail_message_id?(socket, raw_message_id) do
    case Integer.parse(to_string(raw_message_id)) do
      {message_id, _} ->
        is_map(socket.assigns[:local_message]) && socket.assigns.local_message.id == message_id

      _ ->
        false
    end
  end

  defp main_detail_liked?(socket) do
    case socket.assigns[:local_message] do
      %{} = local_message ->
        socket.assigns[:post_interactions]
        |> Kernel.||(%{})
        |> detail_message_interaction(local_message)
        |> Map.get(:liked, false)

      _ ->
        false
    end
  end

  defp main_detail_boosted?(socket) do
    case socket.assigns[:local_message] do
      %{} = local_message ->
        socket.assigns[:post_interactions]
        |> Kernel.||(%{})
        |> detail_message_interaction(local_message)
        |> Map.get(:boosted, false)

      _ ->
        false
    end
  end

  defp main_detail_saved?(socket) do
    case socket.assigns[:local_message] do
      %{} = local_message ->
        detail_message_saved?(socket.assigns[:user_saves] || %{}, local_message)

      _ ->
        false
    end
  end

  defp refresh_main_detail_message(socket) do
    case socket.assigns[:local_message] do
      %{id: message_id} ->
        case Elektrine.Repo.get(Elektrine.Social.Message, message_id) do
          nil ->
            socket

          message ->
            apply_displayed_local_message(socket, message)
        end

      _ ->
        socket
    end
  end

  defp set_main_detail_liked(socket, liked) do
    update_main_detail_interaction_state(socket, fn state ->
      state
      |> Map.put(:liked, liked)
      |> Map.put(:like_delta, 0)
    end)
  end

  defp set_main_detail_boosted(socket, boosted) do
    update_main_detail_interaction_state(socket, fn state ->
      state
      |> Map.put(:boosted, boosted)
      |> Map.put(:boost_delta, 0)
    end)
  end

  defp set_main_detail_saved(socket, saved) do
    local_message = socket.assigns[:local_message]

    if is_map(local_message) do
      detail_post_keys(socket.assigns[:post], local_message)
      |> Enum.reduce(socket.assigns[:user_saves] || %{}, fn key, acc ->
        Map.put(acc, key, saved)
      end)
      |> then(&assign(socket, :user_saves, &1))
    else
      socket
    end
  end

  defp update_main_detail_interaction_state(socket, updater) when is_function(updater, 1) do
    local_message = socket.assigns[:local_message]

    if is_map(local_message) do
      keys = detail_post_keys(socket.assigns[:post], local_message)

      current_state =
        detail_message_interaction(socket.assigns[:post_interactions] || %{}, local_message)

      updated_state = updater.(current_state)

      updated_interactions =
        Enum.reduce(keys, socket.assigns[:post_interactions] || %{}, fn key, acc ->
          Map.put(acc, key, updated_state)
        end)

      assign(socket, :post_interactions, updated_interactions)
    else
      socket
    end
  end

  defp maybe_adjust_like_surface_count(socket, message_id, delta) do
    case Integer.parse(to_string(message_id)) do
      {message_id_int, _} ->
        socket
        |> update_reply_surface_message_count(message_id_int, "_local_like_count", delta)
        |> maybe_adjust_top_level_local_message_like_count(message_id_int, delta)

      _ ->
        socket
    end
  end

  defp maybe_adjust_boost_surface_count(socket, message_id, delta) do
    case Integer.parse(to_string(message_id)) do
      {message_id_int, _} ->
        socket
        |> update_reply_surface_message_count(message_id_int, "_local_share_count", delta)
        |> maybe_adjust_top_level_local_message_boost_count(message_id_int, delta)

      _ ->
        socket
    end
  end

  defp maybe_adjust_top_level_local_message_like_count(socket, message_id, delta) do
    local_message = socket.assigns[:local_message]

    if is_map(local_message) && local_message.id == message_id do
      current_count = local_message.like_count || 0

      assign(socket, :local_message, %{local_message | like_count: max(current_count + delta, 0)})
    else
      socket
    end
  end

  defp maybe_adjust_top_level_local_message_boost_count(socket, message_id, delta) do
    local_message = socket.assigns[:local_message]

    if is_map(local_message) && local_message.id == message_id do
      current_count = local_message.share_count || 0

      assign(socket, :local_message, %{
        local_message
        | share_count: max(current_count + delta, 0)
      })
    else
      socket
    end
  end

  defp maybe_assign_reply_vote_counts(socket, message) do
    socket
    |> maybe_sync_reply_vote_surface(message)
    |> maybe_assign_displayed_reply_message(message)
  end

  defp maybe_sync_reply_vote_surface(socket, %{id: message_id} = message)
       when is_integer(message_id) do
    update_reply_surface_message_value(
      socket,
      message_id,
      "_local_like_count",
      SurfaceHelpers.local_vote_display_count(message)
    )
  end

  defp maybe_sync_reply_vote_surface(socket, _), do: socket

  defp maybe_assign_displayed_reply_message(socket, %{id: message_id} = message)
       when is_integer(message_id) do
    local_message = socket.assigns[:local_message]

    if is_map(local_message) && local_message.id == message_id do
      assign(socket, :local_message, %{
        local_message
        | upvotes: message.upvotes,
          downvotes: message.downvotes,
          score: message.score
      })
    else
      socket
    end
  end

  defp maybe_assign_displayed_reply_message(socket, _), do: socket

  defp update_reply_surface_message_count(socket, message_id, field, delta) do
    replies =
      Enum.map(
        socket.assigns[:replies] || [],
        &maybe_adjust_reply_map_count(&1, message_id, field, delta)
      )

    quick_replies =
      Enum.map(
        socket.assigns[:quick_reply_recent_replies] || [],
        &maybe_adjust_reply_map_count(&1, message_id, field, delta)
      )

    {threaded_replies, thread_reply_actors} =
      build_threaded_replies_with_actor_cache(
        replies,
        field_value(socket.assigns[:post], ["id", :id]),
        socket.assigns.comment_sort
      )

    socket
    |> assign(:replies, replies)
    |> assign(:quick_reply_recent_replies, quick_replies)
    |> assign(:threaded_replies, threaded_replies)
    |> assign(:thread_reply_actors, thread_reply_actors)
  end

  defp update_reply_surface_message_value(socket, message_id, field, value) do
    replies =
      Enum.map(
        socket.assigns[:replies] || [],
        &maybe_set_reply_map_value(&1, message_id, field, value)
      )

    quick_replies =
      Enum.map(
        socket.assigns[:quick_reply_recent_replies] || [],
        &maybe_set_reply_map_value(&1, message_id, field, value)
      )

    {threaded_replies, thread_reply_actors} =
      build_threaded_replies_with_actor_cache(
        replies,
        field_value(socket.assigns[:post], ["id", :id]),
        socket.assigns.comment_sort
      )

    socket
    |> assign(:replies, replies)
    |> assign(:quick_reply_recent_replies, quick_replies)
    |> assign(:threaded_replies, threaded_replies)
    |> assign(:thread_reply_actors, thread_reply_actors)
  end

  defp maybe_adjust_reply_map_count(
         %{"_local_message_id" => message_id} = reply,
         message_id,
         field,
         delta
       )
       when is_integer(message_id) do
    current = reply[field] || 0
    Map.put(reply, field, max(current + delta, 0))
  end

  defp maybe_adjust_reply_map_count(reply, _message_id, _field, _delta), do: reply

  defp maybe_set_reply_map_value(
         %{"_local_message_id" => message_id} = reply,
         message_id,
         field,
         value
       )
       when is_integer(message_id) do
    Map.put(reply, field, value)
  end

  defp maybe_set_reply_map_value(reply, _message_id, _field, _value), do: reply

  defp maybe_assign_displayed_local_message(socket, nil), do: socket

  defp maybe_assign_displayed_local_message(socket, message) do
    apply_displayed_local_message(socket, message)
  end

  defp apply_displayed_local_message(socket, %{id: _message_id} = message) do
    local_message = socket.assigns[:local_message]

    cond do
      is_map(local_message) && local_message.id == message.id ->
        counts = displayed_local_message_counts(message)

        socket
        |> assign(:local_message, apply_display_counts_to_message(local_message, counts))
        |> assign(:post, Counts.apply_counts_to_post_object(socket.assigns[:post], counts))
        |> assign(
          :modal_post,
          apply_display_counts_to_modal_post(socket.assigns[:modal_post], counts)
        )
        |> maybe_update_existing_lemmy_counts(counts)
        |> maybe_update_existing_mastodon_counts(counts)

      is_map(local_message) && Map.get(local_message, :shared_message_id) == message.id &&
          loaded_assoc?(Map.get(local_message, :shared_message)) ->
        counts = displayed_local_message_counts(message)
        shared_message = apply_display_counts_to_message(local_message.shared_message, counts)

        assign(socket, :local_message, %{local_message | shared_message: shared_message})

      true ->
        socket
    end
  end

  defp apply_displayed_local_message(socket, _message), do: socket

  defp displayed_local_message_counts(message) do
    reply_count = Counts.cached_reply_count(message)
    like_count = message.like_count || 0

    %{
      like_count: like_count,
      share_count: message.share_count || 0,
      reply_count: reply_count,
      quote_count: message.quote_count || 0,
      upvotes: Map.get(message, :upvotes) || 0,
      downvotes: Map.get(message, :downvotes) || 0,
      score: max(Map.get(message, :score) || 0, like_count)
    }
  end

  defp apply_display_counts_to_message(message, counts) when is_map(message) do
    message
    |> Map.put(:like_count, Map.get(counts, :like_count))
    |> Map.put(:share_count, Map.get(counts, :share_count))
    |> Map.put(:reply_count, Map.get(counts, :reply_count))
    |> Map.put(:quote_count, Map.get(counts, :quote_count))
    |> Map.put(:upvotes, Map.get(counts, :upvotes))
    |> Map.put(:downvotes, Map.get(counts, :downvotes))
    |> Map.put(:score, Map.get(counts, :score))
  end

  defp apply_display_counts_to_modal_post(nil, _counts), do: nil

  defp apply_display_counts_to_modal_post(%{} = post, counts) do
    if Map.has_key?(post, "id") do
      Counts.apply_counts_to_post_object(post, counts)
    else
      counts
      |> Enum.reduce(post, fn {field, value}, acc ->
        if is_integer(value) && Map.has_key?(acc, field) do
          Map.put(acc, field, value)
        else
          acc
        end
      end)
    end
  end

  defp maybe_update_existing_lemmy_counts(socket, counts) do
    case socket.assigns[:lemmy_counts] do
      counts_map when is_map(counts_map) ->
        assign(
          socket,
          :lemmy_counts,
          counts_map
          |> Map.put(:upvotes, Map.get(counts, :upvotes))
          |> Map.put(:downvotes, Map.get(counts, :downvotes))
          |> Map.put(:score, Map.get(counts, :score))
          |> Map.put(:comments, Map.get(counts, :reply_count))
        )

      _ ->
        socket
    end
  end

  defp maybe_update_existing_mastodon_counts(socket, counts) do
    case socket.assigns[:mastodon_counts] do
      counts_map when is_map(counts_map) ->
        assign(
          socket,
          :mastodon_counts,
          counts_map
          |> Map.put(:favourites_count, Map.get(counts, :like_count))
          |> Map.put(:reblogs_count, Map.get(counts, :share_count))
          |> Map.put(:replies_count, Map.get(counts, :reply_count))
        )

      _ ->
        socket
    end
  end

  defp maybe_track_trust_detail_view(socket, nil, _source), do: socket

  defp maybe_track_trust_detail_view(socket, message, source) do
    current_user = socket.assigns[:current_user]

    if connected?(socket) && current_user && message && !socket.assigns[:trust_topic_tracked] do
      Social.track_post_view(current_user.id, message.id, completed: true, source: source)
      assign(socket, :trust_topic_tracked, true)
    else
      socket
    end
  end

  defp format_activitypub_date(date), do: APHelpers.format_activitypub_date(date)
  defp get_collection_total_items(coll), do: APHelpers.get_collection_total(coll)
  defp get_follower_count(meta), do: APHelpers.get_follower_count(meta)
  defp get_status_count(meta), do: APHelpers.get_status_count(meta)
  defp format_join_date(date), do: APHelpers.format_join_date(date)

  defp load_post_interactions(posts, user_id) when is_list(posts) do
    posts
    |> APHelpers.load_post_interactions(user_id)
    |> Map.merge(load_local_post_interactions(posts, user_id))
  end

  defp load_post_interactions(_, _), do: %{}

  defp load_local_post_interactions(posts, user_id) when is_list(posts) do
    import Ecto.Query

    message_ids =
      posts
      |> Enum.map(&local_interaction_message_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if message_ids == [] do
      %{}
    else
      liked_ids =
        Elektrine.Social.PostLike
        |> where([like], like.user_id == ^user_id and like.message_id in ^message_ids)
        |> select([like], like.message_id)
        |> Elektrine.Repo.all()
        |> MapSet.new()

      boosted_ids =
        Elektrine.Social.PostBoost
        |> where([boost], boost.user_id == ^user_id and boost.message_id in ^message_ids)
        |> select([boost], boost.message_id)
        |> Elektrine.Repo.all()
        |> MapSet.new()

      votes_by_id =
        Elektrine.Social.MessageVote
        |> where([vote], vote.user_id == ^user_id and vote.message_id in ^message_ids)
        |> select([vote], {vote.message_id, vote.vote_type})
        |> Elektrine.Repo.all()
        |> Map.new()

      posts
      |> Enum.flat_map(fn post ->
        case local_interaction_message_id(post) do
          message_id when is_integer(message_id) ->
            state = %{
              liked: MapSet.member?(liked_ids, message_id),
              boosted: MapSet.member?(boosted_ids, message_id),
              like_delta: 0,
              boost_delta: 0,
              vote: Map.get(votes_by_id, message_id),
              vote_delta: 0
            }

            post
            |> local_interaction_keys(message_id)
            |> Enum.map(&{&1, state})

          _ ->
            []
        end
      end)
      |> Map.new()
    end
  end

  defp load_local_post_interactions(_, _), do: %{}

  defp local_interaction_message_id(%Elektrine.Social.Message{id: id}) when is_integer(id), do: id

  defp local_interaction_message_id(%{} = post) do
    reply_local_message_id(post) ||
      case field_value(post, [:id, "id"]) do
        id when is_integer(id) -> id
        _ -> nil
      end
  end

  defp local_interaction_message_id(_), do: nil

  defp usable_interaction_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      "unknown" -> nil
      trimmed -> trimmed
    end
  end

  defp usable_interaction_id(value) when is_integer(value), do: value
  defp usable_interaction_id(_), do: nil

  defp local_interaction_keys(post, message_id) do
    [message_id, reply_surface_ref(post), field_value(post, ["id", :id])]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&PostInteractions.normalize_key/1)
    |> Enum.uniq()
  end

  defp get_or_store_remote_post(activitypub_id, actor_uri) do
    APHelpers.get_or_store_remote_post(activitypub_id, actor_uri)
  end

  defp build_threaded_replies_with_actor_cache(replies, post_id, sort) do
    Threading.build_threaded_replies_with_actor_cache(replies, post_id, sort)
  end

  defp log_remote_post_timing(_step, _started_at, _metadata), do: :ok

  defp field_value(nil, _keys), do: nil

  defp field_value(value, keys) when is_list(keys) do
    Enum.find_value(keys, fn key -> field_value(value, key) end)
  end

  defp field_value(%_{} = value, key) when is_atom(key), do: Map.get(value, key)
  defp field_value(%{} = value, key), do: Map.get(value, key)
  defp field_value(_, _), do: nil

  defp strict_fetch_remote_object(post_id) when is_binary(post_id) do
    ActivityPub.fetch_remote_object_strict(post_id)
  end

  defp strict_fetch_remote_object(_post_id), do: {:error, :invalid_post_id}

  defp fetch_remote_object_for_detail(post_id) when is_binary(post_id) do
    ActivityPub.fetch_remote_object(post_id)
  end

  defp fetch_remote_object_for_detail(_post_id), do: {:error, :invalid_post_id}

  defp strict_fetch_remote_actor(actor_uri) when is_binary(actor_uri) do
    ActivityPub.fetch_and_cache_actor(actor_uri, allow_recovery: false)
  rescue
    error in Postgrex.Error ->
      if postgres_error_code(error) == :index_corrupted do
        Logger.error(
          "Postgres index corruption while fetching remote actor: #{Exception.message(error)}"
        )

        {:error, :local_actor_index_corrupted}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp strict_fetch_remote_actor(_actor_uri), do: {:error, :invalid_actor_uri}

  defp fetch_remote_actor_for_detail(actor_uri) when is_binary(actor_uri) do
    ActivityPub.fetch_and_cache_actor(actor_uri, allow_recovery: true)
  rescue
    error in Postgrex.Error ->
      if postgres_error_code(error) == :index_corrupted do
        Logger.error(
          "Postgres index corruption while fetching remote detail actor: #{Exception.message(error)}"
        )

        {:error, :index_corrupted}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp fetch_remote_actor_for_detail(_actor_uri), do: {:error, :invalid_actor_uri}

  defp store_remote_post_safely(post_object, actor_uri) do
    ActivityPub.Handler.store_remote_post(post_object, actor_uri)
  rescue
    error in Postgrex.Error ->
      if unique_activitypub_violation?(error) do
        {:ok, :already_exists}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp unique_activitypub_violation?(%Postgrex.Error{postgres: postgres}) when is_map(postgres) do
    postgres[:code] in [:unique_violation, "unique_violation", "23505"] &&
      to_string(postgres[:constraint] || "") == "messages_activitypub_id_index"
  end

  defp unique_activitypub_violation?(_), do: false

  defp postgres_error_code(%Postgrex.Error{postgres: postgres}) when is_map(postgres) do
    case postgres[:code] do
      "XX002" -> :index_corrupted
      code -> code
    end
  end

  defp postgres_error_code(_), do: nil

  defp hydrate_ancestor_surface_data(socket, ancestors) when is_list(ancestors) do
    socket =
      assign(
        socket,
        :post_reactions,
        SurfaceHelpers.merge_local_ancestor_reactions(socket.assigns.post_reactions, ancestors)
      )

    if socket.assigns[:current_user] do
      user_id = socket.assigns.current_user.id
      ancestor_posts = Enum.map(ancestors, & &1.post)
      remote_interactions = load_post_interactions(ancestor_posts, user_id)

      socket
      |> assign(
        :post_interactions,
        socket.assigns.post_interactions
        |> Map.merge(remote_interactions)
        |> SurfaceHelpers.merge_local_ancestor_interactions(ancestors, user_id)
      )
      |> assign(
        :user_saves,
        SurfaceHelpers.merge_local_ancestor_saves(socket.assigns.user_saves, ancestors, user_id)
      )
    else
      socket
    end
  end

  defp hydrate_ancestor_surface_data(socket, _), do: socket

  defp redirect_to_external_url(socket, url) do
    case SafeExternalURL.normalize(url) do
      {:ok, safe_url} -> redirect(socket, external: safe_url)
      {:error, _reason} -> put_flash(socket, :error, "Invalid external URL")
    end
  end
end
