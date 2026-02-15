defmodule ElektrineWeb.DiscussionsLive.Community do
  @moduledoc """
  Community discussions LiveView.

  This module has been refactored to delegate all handle_event calls to focused
  operation modules via Router. The core responsibilities are:
  - mount: Initialize LiveView state and subscriptions
  - render: Render the UI (in template file)
  - handle_params: Handle URL parameter changes
  - handle_info: Handle PubSub broadcasts and real-time updates

  All event handlers are organized into operation modules under operations/:
  - PostOperations: Creating, editing, deleting, pinning, locking posts
  - ModerationOperations: Bans, timeouts, warnings, auto-mod, post approval
  - MemberOperations: Joining, leaving, searching members, following
  - VotingOperations: Post voting, poll voting, showing voters
  - FlairOperations: Creating, editing, deleting flairs
  - UiOperations: Modals, navigation, view switching, sorting
  """
  use ElektrineWeb, :live_view

  alias Elektrine.{Social, Messaging}
  alias ElektrineWeb.DiscussionsLive.Operations.SortHelpers
  alias ElektrineWeb.DiscussionsLive.Router

  import ElektrineWeb.Components.Social.ContentJourney
  import ElektrineWeb.Components.User.Avatar
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.Social.EmbeddedPost
  import ElektrineWeb.Components.Social.PostActions
  import ElektrineWeb.HtmlHelpers
  import ElektrineWeb.Components.Social.Poll

  @impl true
  def mount(%{"name" => community_name}, _session, socket) do
    import Ecto.Query
    user = socket.assigns[:current_user]

    # Find community by name (use Repo.one with limit to handle potential duplicates)
    community =
      from(c in Elektrine.Messaging.Conversation,
        where: c.name == ^community_name and c.type == "community",
        order_by: [asc: c.inserted_at],
        limit: 1
      )
      |> Elektrine.Repo.one()

    if community do
      community_id = community.id

      # Check if current user is a member and their role (needed for initial UI state)
      {is_member, is_moderator} =
        if user do
          member = Messaging.get_conversation_member(community_id, user.id)
          is_member = !is_nil(member) && is_nil(member.left_at)
          is_moderator = member && member.role in ["moderator", "admin", "owner"]
          {is_member, is_moderator}
        else
          {false, false}
        end

      # Allow everyone to view all communities
      if connected?(socket) do
        # Subscribe to community updates
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "conversation:#{community_id}")
        # Subscribe to discussion activity for live updates
        Phoenix.PubSub.subscribe(Elektrine.PubSub, "discussion:#{community_id}")

        # Trigger async data loading
        send(self(), {:load_community_data, community_id, is_moderator})
      end

      community_slug = String.downcase(community.name) |> String.replace(~r/[^a-z0-9]+/, "-")

      # Build meta tags for social sharing
      meta_description = build_community_description(community)
      og_image = get_community_image(community)
      current_url = "#{ElektrineWeb.Endpoint.url()}/discussions/#{community.name}"

      socket =
        socket
        |> assign(
          :page_title,
          "!#{community_slug}@#{Elektrine.ActivityPub.instance_domain()} - #{community.name}"
        )
        |> assign(:meta_description, meta_description)
        |> assign(:og_image, og_image)
        |> assign(:current_url, current_url)
        |> assign(:community, community)
        |> assign(:community_slug, community_slug)
        |> assign(:discussion_posts, [])
        |> assign(:members, [])
        |> assign(:filtered_members, [])
        |> assign(:member_search, "")
        |> assign(:is_member, is_member)
        |> assign(:is_moderator, is_moderator)
        |> assign(:flairs, [])
        |> assign(:pinned_posts, [])
        |> assign(:user_votes, %{})
        |> assign(:selected_flair_id, nil)
        # "posts", "members", or "flairs"
        |> assign(:current_view, "posts")
        |> assign(:sort_by, "hot")
        |> assign(:posting_cadence, "No recent posts")
        |> assign(:show_new_post, false)
        # text, link, image, poll
        |> assign(:post_type, "text")
        |> assign(:new_post_title, "")
        |> assign(:new_post_content, "")
        # Track number of poll option inputs
        |> assign(:poll_options, ["", ""])
        |> assign(:link_url, nil)
        |> assign(:link_title, nil)
        |> assign(:show_flair_modal, false)
        |> assign(:editing_flair, nil)
        |> assign(:reply_to_post, nil)
        |> assign(:reply_content, "")
        |> assign(:show_report_modal, false)
        |> assign(:report_type, nil)
        |> assign(:report_id, nil)
        |> assign(:report_metadata, %{})
        |> assign(:user_follows, %{})
        |> assign(:show_voters_modal, false)
        |> assign(:voters_tab, "upvotes")
        |> assign(:upvoters, [])
        |> assign(:available_conversations, [])
        |> assign(:downvoters, [])
        |> assign(:is_owner, user && community.creator_id == user.id)
        |> assign(:banned_users, [])
        |> assign(:show_ban_modal, false)
        |> assign(:ban_target_user, nil)
        |> assign(:pending_posts, [])
        |> assign(:show_warning_modal, false)
        |> assign(:warning_target_user, nil)
        |> assign(:warning_message_id, nil)
        |> assign(:show_timeout_modal, false)
        |> assign(:timeout_target_user, nil)
        |> assign(:show_note_modal, false)
        |> assign(:note_target_user, nil)
        |> assign(:user_notes, %{})
        |> assign(:mod_log, [])
        |> assign(:auto_mod_rules, [])
        |> assign(:show_rule_modal, false)
        |> assign(:editing_rule, nil)
        |> assign(:show_user_mod_status_modal, false)
        |> assign(:mod_status_target_user, nil)
        |> assign(:user_mod_data, %{})
        |> assign(:show_image_upload_modal, false)
        |> assign(:pending_media_urls, [])
        |> assign(:pending_media_alt_texts, %{})
        |> assign(:show_image_modal, false)
        |> assign(:modal_image_url, nil)
        |> assign(:modal_images, [])
        |> assign(:modal_image_index, 0)
        |> assign(:modal_post, nil)
        |> assign(:loading_community, true)

      # Allow image, video, and audio uploads for authenticated members
      socket =
        if user && is_member do
          allow_upload(socket, :discussion_attachments,
            accept: ~w(.jpg .jpeg .png .gif .webp .mp4 .webm .ogv .mov .mp3 .wav),
            max_entries: 4,
            # 50MB to accommodate video/audio files
            max_file_size: 50_000_000
          )
        else
          socket
        end

      {:ok, socket}
    else
      # Invalid community identifier
      {:ok, push_navigate(socket, to: ~p"/communities")}
    end
  end

  @impl true
  def handle_event(event_name, params, socket) do
    # Delegate all events to the router
    Router.route_event(event_name, params, socket)
  end

  @impl true
  def handle_info({:community_updated, updated_community}, socket) do
    # Update the community data for all connected users
    user = socket.assigns.current_user

    # Check if the user still has access after the visibility change
    if updated_community.is_public || (user && is_member?(updated_community.id, user.id)) do
      {:noreply, assign(socket, :community, updated_community)}
    else
      # User no longer has access to the private community
      {:noreply,
       socket
       |> put_flash(:error, "This community is now private and you are not a member")
       |> push_navigate(to: ~p"/communities")}
    end
  end

  def handle_info({:member_role_updated, user_id, new_role}, socket) do
    # Update the members list when a role changes
    members = Messaging.get_conversation_members(socket.assigns.community.id)

    # Update is_moderator if the current user's role changed
    is_moderator =
      if socket.assigns.current_user && socket.assigns.current_user.id == user_id do
        new_role in ["moderator", "admin", "owner"]
      else
        socket.assigns.is_moderator
      end

    {:noreply,
     socket
     |> assign(:members, members)
     |> assign(:is_moderator, is_moderator)}
  end

  def handle_info({:new_message, message}, socket) do
    # Add new discussion posts to the community
    if message.conversation_id == socket.assigns.community.id && is_nil(message.reply_to_id) do
      # Use the broadcasted message which already has all the data including title
      # Only reload associations if they're missing
      message =
        if is_nil(message.sender) or is_nil(message.reactions) do
          preloads =
            Elektrine.Messaging.Messages.discussion_post_preloads() ++
              [:replies, reactions: [:user, :remote_actor]]

          Elektrine.Repo.preload(
            message,
            preloads,
            force: true
          )
        else
          message
        end

      # Only add if it's a discussion-related post (discussion, poll, link, or legacy post with nil post_type)
      if message.post_type in ["discussion", "poll", "link", "post"] || is_nil(message.post_type) do
        # Decrypt content before adding to list
        message = Elektrine.Messaging.Message.decrypt_content(message)
        updated_posts = [message | socket.assigns.discussion_posts]

        {:noreply,
         socket
         |> assign(:discussion_posts, updated_posts)
         |> assign(
           :posting_cadence,
           calculate_posting_cadence(updated_posts ++ (socket.assigns.pinned_posts || []))
         )}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:post_liked, %{message_id: message_id, like_count: like_count}}, socket) do
    # Update like count in real-time
    updated_posts =
      Enum.map(socket.assigns.discussion_posts, fn post ->
        if post.id == message_id do
          %{post | like_count: like_count}
        else
          post
        end
      end)

    {:noreply, assign(socket, :discussion_posts, updated_posts)}
  end

  def handle_info({:message_link_preview_updated, message}, socket) do
    # Update the discussion post when its link preview is ready
    if message.conversation_id == socket.assigns.community.id do
      # Ensure hashtags are loaded (defensive programming for race conditions)
      message =
        if Ecto.assoc_loaded?(message.hashtags) do
          message
        else
          Elektrine.Repo.preload(message, [:hashtags])
        end

      updated_posts =
        Enum.map(socket.assigns.discussion_posts, fn post ->
          if post.id == message.id do
            # Preserve the title and other fields from the original post
            # Only update the link_preview field
            %{post | link_preview: message.link_preview}
          else
            post
          end
        end)

      {:noreply, assign(socket, :discussion_posts, updated_posts)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:post_voted,
         %{message_id: message_id, upvotes: upvotes, downvotes: downvotes, score: score}},
        socket
      ) do
    # Update vote counts in real-time for both discussion and pinned posts
    updated_posts =
      Enum.map(socket.assigns.discussion_posts, fn post ->
        if post.id == message_id do
          %{post | upvotes: upvotes, downvotes: downvotes, score: score}
        else
          post
        end
      end)

    updated_pinned =
      Enum.map(socket.assigns.pinned_posts, fn post ->
        if post.id == message_id do
          %{post | upvotes: upvotes, downvotes: downvotes, score: score}
        else
          post
        end
      end)

    {:noreply,
     socket
     |> assign(:discussion_posts, updated_posts)
     |> assign(:pinned_posts, updated_pinned)}
  end

  def handle_info({:message_pinned, message}, socket) do
    # Reload pinned posts when a message is pinned
    pinned_posts =
      Messaging.list_pinned_messages(socket.assigns.community.id)
      |> Elektrine.Repo.preload(Elektrine.Messaging.Messages.discussion_post_preloads())
      |> Enum.map(&Elektrine.Messaging.Message.decrypt_content/1)

    # Also update the post in discussion_posts if it's there
    updated_discussion_posts =
      Enum.map(socket.assigns.discussion_posts, fn post ->
        if post.id == message.id do
          %{
            post
            | is_pinned: true,
              pinned_at: message.pinned_at,
              pinned_by_id: message.pinned_by_id
          }
        else
          post
        end
      end)

    {:noreply,
     socket
     |> assign(:pinned_posts, pinned_posts)
     |> assign(:discussion_posts, updated_discussion_posts)}
  end

  def handle_info({:message_unpinned, message}, socket) do
    # Reload pinned posts when a message is unpinned
    pinned_posts =
      Messaging.list_pinned_messages(socket.assigns.community.id)
      |> Elektrine.Repo.preload(Elektrine.Messaging.Messages.discussion_post_preloads())
      |> Enum.map(&Elektrine.Messaging.Message.decrypt_content/1)

    # Also update the post in discussion_posts if it's there
    updated_discussion_posts =
      Enum.map(socket.assigns.discussion_posts, fn post ->
        if post.id == message.id do
          %{post | is_pinned: false, pinned_at: nil, pinned_by_id: nil}
        else
          post
        end
      end)

    {:noreply,
     socket
     |> assign(:pinned_posts, pinned_posts)
     |> assign(:discussion_posts, updated_discussion_posts)}
  end

  def handle_info({:thread_locked, message}, socket) do
    # Update locked status in discussion_posts
    updated_discussion_posts =
      Enum.map(socket.assigns.discussion_posts, fn post ->
        if post.id == message.id do
          %{
            post
            | locked_at: message.locked_at,
              locked_by_id: message.locked_by_id,
              lock_reason: message.lock_reason
          }
        else
          post
        end
      end)

    {:noreply, assign(socket, :discussion_posts, updated_discussion_posts)}
  end

  def handle_info({:thread_unlocked, message}, socket) do
    # Update locked status in discussion_posts
    updated_discussion_posts =
      Enum.map(socket.assigns.discussion_posts, fn post ->
        if post.id == message.id do
          %{post | locked_at: nil, locked_by_id: nil, lock_reason: nil}
        else
          post
        end
      end)

    {:noreply, assign(socket, :discussion_posts, updated_discussion_posts)}
  end

  # Async data loading handler
  def handle_info({:load_community_data, community_id, is_moderator}, socket) do
    user = socket.assigns[:current_user]

    # Get discussion posts for this community
    discussion_posts =
      SortHelpers.load_posts(community_id, socket.assigns.sort_by, limit: 20)

    # Get community members
    members = Messaging.get_conversation_members(community_id)

    # Get community flairs
    flairs =
      if is_moderator do
        Messaging.list_community_flairs(community_id)
      else
        Messaging.list_enabled_community_flairs(community_id)
      end

    # Get pinned posts
    pinned_posts =
      Messaging.list_pinned_messages(community_id)
      |> Elektrine.Repo.preload(Elektrine.Messaging.Messages.discussion_post_preloads())
      |> Enum.map(&Elektrine.Messaging.Message.decrypt_content/1)

    # Initialize user follows map using batch query
    user_follows =
      if user do
        user_ids =
          discussion_posts
          |> Enum.map(& &1.sender_id)
          |> Enum.uniq()

        Elektrine.Profiles.following_many?(user.id, user_ids)
      else
        %{}
      end

    # Load user's votes for all posts
    user_votes =
      if user do
        all_post_ids =
          (discussion_posts ++ pinned_posts)
          |> Enum.map(& &1.id)

        Social.get_user_votes(user.id, all_post_ids)
      else
        %{}
      end

    # Load moderator-only data in parallel if needed
    {banned_users, pending_posts, mod_log, auto_mod_rules} =
      if is_moderator do
        banned_task = Task.async(fn -> Messaging.list_community_bans(community_id) end)

        pending_task =
          Task.async(fn ->
            Elektrine.Messaging.ModerationTools.list_pending_posts(community_id)
            |> Enum.map(&Elektrine.Messaging.Message.decrypt_content/1)
          end)

        mod_log_task =
          Task.async(fn ->
            Elektrine.Messaging.ModerationTools.get_moderation_log(community_id, limit: 50)
          end)

        rules_task =
          Task.async(fn ->
            Elektrine.Messaging.ModerationTools.list_auto_mod_rules(community_id)
          end)

        {
          Task.await(banned_task, 5000),
          Task.await(pending_task, 5000),
          Task.await(mod_log_task, 5000),
          Task.await(rules_task, 5000)
        }
      else
        {[], [], [], []}
      end

    {:noreply,
     socket
     |> assign(:discussion_posts, discussion_posts)
     |> assign(:members, members)
     |> assign(:filtered_members, members)
     |> assign(:flairs, flairs)
     |> assign(:pinned_posts, pinned_posts)
     |> assign(:user_follows, user_follows)
     |> assign(:user_votes, user_votes)
     |> assign(:banned_users, banned_users)
     |> assign(:pending_posts, pending_posts)
     |> assign(:mod_log, mod_log)
     |> assign(:auto_mod_rules, auto_mod_rules)
     |> assign(:posting_cadence, calculate_posting_cadence(discussion_posts ++ pinned_posts))
     |> assign(:loading_community, false)}
  end

  @impl true
  def handle_info({:report_submitted, _reportable_type, _reportable_id}, socket) do
    {:noreply,
     socket
     |> assign(:show_report_modal, false)
     |> assign(:report_type, nil)
     |> assign(:report_id, nil)
     |> assign(:report_metadata, %{})
     |> put_flash(:info, "Report submitted. Thanks for helping keep this community safe.")}
  end

  def handle_info(_info, socket) do
    {:noreply, socket}
  end

  # Helper functions (kept in main module as they're used by handle_info)

  defp is_member?(community_id, user_id) do
    import Ecto.Query

    Elektrine.Repo.exists?(
      from cm in Elektrine.Messaging.ConversationMember,
        where:
          cm.conversation_id == ^community_id and
            cm.user_id == ^user_id and
            is_nil(cm.left_at)
    )
  end

  def extract_youtube_id(url) when is_binary(url) do
    patterns = [
      ~r/(?:youtube\.com\/watch\?v=|youtu\.be\/|youtube\.com\/embed\/)([a-zA-Z0-9_-]{11})/,
      ~r/youtube\.com\/watch\?.*v=([a-zA-Z0-9_-]{11})/
    ]

    Enum.find_value(patterns, fn pattern ->
      case Regex.run(pattern, url) do
        [_, video_id] -> video_id
        _ -> nil
      end
    end)
  end

  def extract_youtube_id(_), do: nil

  # Delegate to centralized safe helper to prevent XSS
  defp make_links_clickable(text) do
    text
    |> make_content_safe_with_links()
    |> preserve_line_breaks()
  end

  defp action_badge_color(action_type) do
    case action_type do
      "ban" -> "badge-error"
      "timeout" -> "badge-warning"
      "warn" -> "badge-info"
      "delete" -> "badge-error"
      "lock" -> "badge-warning"
      "unlock" -> "badge-success"
      "approve" -> "badge-success"
      "reject" -> "badge-error"
      "remove_timeout" -> "badge-success"
      _ -> "badge-ghost"
    end
  end

  defp action_verb(action_type) do
    case action_type do
      "ban" -> "banned"
      "timeout" -> "timed out"
      "warn" -> "warned"
      "delete" -> "deleted post by"
      "lock" -> "locked thread"
      "unlock" -> "unlocked thread"
      "approve" -> "approved post by"
      "reject" -> "rejected post by"
      "remove_timeout" -> "removed timeout from"
      _ -> action_type
    end
  end

  defp error_to_string(:too_large), do: "Image is too large (max 10MB)"

  defp error_to_string(:not_accepted),
    do: "Invalid file type. Please upload JPG, PNG, GIF, or WEBP"

  defp error_to_string(:too_many_files), do: "Maximum 4 images allowed"
  defp error_to_string(_), do: "Upload error"

  # Helper for templates - generates SEO-friendly discussion URL
  defp generate_discussion_url(community, post) do
    community_name = community.name
    # Always use SEO-friendly URL with slug (falls back to just ID if no title)
    slug = Elektrine.Utils.Slug.discussion_url_slug(post.id, post.title)
    ~p"/communities/#{community_name}/post/#{slug}"
  end

  # Build OG description for community
  defp build_community_description(community) do
    base = "!#{community.name} - A community on Elektrine"

    if community.description && String.trim(community.description) != "" do
      desc =
        community.description
        |> HtmlSanitizeEx.strip_tags()
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
        |> String.slice(0, 150)

      if String.length(community.description) > 150 do
        "#{desc}..."
      else
        desc
      end
    else
      base
    end
  end

  # Get community image for OG tag
  defp get_community_image(community) do
    banner = Map.get(community, :banner_url)
    avatar = Map.get(community, :avatar_url)

    cond do
      banner && banner != "" ->
        Elektrine.Uploads.attachment_url(banner)

      avatar && avatar != "" ->
        Elektrine.Uploads.attachment_url(avatar)

      true ->
        nil
    end
  end

  def pin_role(post) do
    get_in(post.media_metadata || %{}, ["community_pin_type"])
  end

  defp calculate_posting_cadence(posts) do
    if Enum.empty?(posts) do
      "No recent posts"
    else
      one_week_ago = NaiveDateTime.add(NaiveDateTime.utc_now(), -7 * 24 * 60 * 60, :second)

      weekly_posts =
        Enum.count(posts, fn post ->
          NaiveDateTime.compare(post.inserted_at, one_week_ago) != :lt
        end)

      cond do
        weekly_posts >= 28 -> "#{weekly_posts} posts/week (high activity)"
        weekly_posts >= 10 -> "#{weekly_posts} posts/week (steady activity)"
        weekly_posts >= 3 -> "#{weekly_posts} posts/week (growing)"
        weekly_posts > 0 -> "#{weekly_posts} post/week"
        true -> "Occasional posts"
      end
    end
  end
end
