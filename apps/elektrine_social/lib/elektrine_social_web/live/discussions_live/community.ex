defmodule ElektrineSocialWeb.DiscussionsLive.Community do
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
  use ElektrineSocialWeb, :live_view

  alias Elektrine.{Messaging, Profiles, Social}
  alias ElektrineSocialWeb.DiscussionsLive.Operations.SortHelpers
  alias ElektrineSocialWeb.DiscussionsLive.Router

  import ElektrineSocialWeb.Components.Social.ContentJourney
  import Elektrine.Components.User.Avatar
  import Elektrine.Components.User.UsernameEffects
  import ElektrineSocialWeb.Components.Platform.ENav
  import ElektrineSocialWeb.Components.Social.EmbeddedPost
  import ElektrineSocialWeb.Components.Social.PostActions
  import ElektrineWeb.Components.Social.YoutubePreview, only: [rich_link_preview: 1]
  import ElektrineWeb.HtmlHelpers
  import ElektrineSocialWeb.Components.Social.Poll

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

      is_remote_following =
        if user && community.is_federated_mirror && is_integer(community.remote_group_actor_id) do
          Profiles.following_remote_actor?(user.id, community.remote_group_actor_id)
        else
          false
        end

      if community.is_public || is_member do
        if connected?(socket) do
          # Subscribe to community updates
          Phoenix.PubSub.subscribe(Elektrine.PubSub, "conversation:#{community_id}")
          # Subscribe to discussion activity for live updates
          Phoenix.PubSub.subscribe(Elektrine.PubSub, "discussion:#{community_id}")
          Phoenix.PubSub.subscribe(Elektrine.PubSub, "timeline:public")

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
          |> assign(:is_remote_following, is_remote_following)
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
          |> assign(:pending_media_attachments, [])
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
        {:ok,
         socket
         |> put_flash(:error, "You don't have permission to view this community")
         |> push_navigate(to: ~p"/communities")}
      end
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
    if updated_community.is_public || (user && member?(updated_community.id, user.id)) do
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

  def handle_info({:post_counts_updated, %{message_id: message_id, counts: counts}}, socket) do
    update_fn = fn posts ->
      Enum.map(posts, fn post ->
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
    end

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

    {:noreply,
     socket
     |> update(:discussion_posts, update_fn)
     |> update(:pinned_posts, update_fn)
     |> assign(:modal_post, updated_modal_post)}
  end

  def handle_info({:message_link_preview_updated, message}, socket) do
    # Update the discussion post when its link preview is ready
    if message.conversation_id == socket.assigns.community.id do
      message_id = message.id

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

      updated_pinned_posts =
        Enum.map(socket.assigns.pinned_posts, fn post ->
          if post.id == message.id do
            %{post | link_preview: message.link_preview}
          else
            post
          end
        end)

      updated_modal_post =
        case socket.assigns[:modal_post] do
          %{id: ^message_id} = post -> %{post | link_preview: message.link_preview}
          post -> post
        end

      {:noreply,
       socket
       |> assign(:discussion_posts, updated_posts)
       |> assign(:pinned_posts, updated_pinned_posts)
       |> assign(:modal_post, updated_modal_post)}
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

  defp member?(community_id, user_id) do
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

  defp community_modals(assigns) do
    ~H"""
    <!-- Report Modal -->
    <%= if @show_report_modal do %>
      <.live_component
        module={Elektrine.Components.ReportModal}
        id="report-modal"
        reporter_id={@current_user.id}
        reportable_type={@report_type}
        reportable_id={@report_id}
        additional_metadata={@report_metadata}
      />
    <% end %>

    <!-- Flair Modal -->
    <%= if @show_flair_modal && @is_moderator do %>
      <div class="modal modal-open">
        <div class="modal-box modal-surface">
          <div class="flex justify-between items-center mb-4">
            <h3 class="font-bold text-lg">
              {if @editing_flair, do: "Edit Flair", else: "Add New Flair"}
            </h3>
            <button type="button" phx-click="cancel_flair" class="btn btn-ghost btn-sm btn-circle">
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>

          <.form for={%{}} phx-submit={if @editing_flair, do: "update_flair", else: "create_flair"}>
            <%= if @editing_flair do %>
              <input type="hidden" name="flair_id" value={@editing_flair.id} />
            <% end %>

            <div class="form-control mb-4">
              <label class="label">
                <span class="label-text">Flair Name</span>
              </label>
              <input
                type="text"
                name="name"
                value={if @editing_flair, do: @editing_flair.name, else: ""}
                class="input input-bordered"
                placeholder="e.g., Discussion, Question, News"
                maxlength="30"
                required
              />
            </div>

            <div class="form-control mb-4">
              <label class="label cursor-pointer">
                <span class="label-text">Moderator Only</span>
                <input
                  type="checkbox"
                  name="is_mod_only"
                  checked={if @editing_flair, do: @editing_flair.is_mod_only, else: false}
                  class="checkbox checkbox-error"
                />
              </label>
            </div>

            <div class="form-control mb-4">
              <label class="label cursor-pointer">
                <span class="label-text">Enabled</span>
                <input
                  type="checkbox"
                  name="is_enabled"
                  checked={if @editing_flair, do: @editing_flair.is_enabled, else: true}
                  class="checkbox checkbox-error"
                />
              </label>
            </div>

            <div class="modal-action">
              <button type="button" phx-click="cancel_flair" class="btn btn-ghost">Cancel</button>
              <button type="submit" class="btn btn-secondary">
                {if @editing_flair, do: "Update", else: "Create"}
              </button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="cancel_flair"></div>
      </div>
    <% end %>

    <!-- Voters Modal -->
    <%= if @show_voters_modal do %>
      <div class="modal modal-open">
        <div class="modal-box modal-surface max-w-2xl">
          <div class="flex justify-between items-center mb-4">
            <h3 class="font-bold text-lg">Votes</h3>
            <button
              type="button"
              phx-click="close_voters_modal"
              class="btn btn-ghost btn-sm btn-circle"
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>

          <div class="tabs tabs-boxed mb-4">
            <button
              class={["tab", if(@voters_tab == "upvotes", do: "tab-active")]}
              phx-click="switch_voters_tab"
              phx-value-tab="upvotes"
            >
              <.icon name="hero-arrow-up" class="w-4 h-4 mr-1" /> Upvotes ({length(@upvoters || [])})
            </button>
            <button
              class={["tab", if(@voters_tab == "downvotes", do: "tab-active")]}
              phx-click="switch_voters_tab"
              phx-value-tab="downvotes"
            >
              <.icon name="hero-arrow-down" class="w-4 h-4 mr-1" />
              Downvotes ({length(@downvoters || [])})
            </button>
          </div>

          <div class="space-y-2 max-h-96 overflow-y-auto">
            <%= if @voters_tab == "upvotes" do %>
              <%= if @upvoters && length(@upvoters) > 0 do %>
                <%= for voter <- @upvoters do %>
                  <.link
                    href={~p"/#{voter.handle || voter.username}"}
                    class="flex items-center gap-3 p-2 hover:bg-base-200 rounded-lg"
                  >
                    <.user_avatar user={voter} size="sm" />
                    <div>
                      <div class="font-medium">
                        <.username_with_effects user={voter} display_name={true} verified_size="sm" />
                      </div>
                      <div class="text-sm opacity-70">@{voter.handle || voter.username}</div>
                    </div>
                  </.link>
                <% end %>
              <% else %>
                <p class="text-center py-4 opacity-50">No upvotes yet</p>
              <% end %>
            <% else %>
              <%= if @downvoters && length(@downvoters) > 0 do %>
                <%= for voter <- @downvoters do %>
                  <.link
                    href={~p"/#{voter.handle || voter.username}"}
                    class="flex items-center gap-3 p-2 hover:bg-base-200 rounded-lg"
                  >
                    <.user_avatar user={voter} size="sm" />
                    <div>
                      <div class="font-medium">
                        <.username_with_effects user={voter} display_name={true} verified_size="sm" />
                      </div>
                      <div class="text-sm opacity-70">@{voter.handle || voter.username}</div>
                    </div>
                  </.link>
                <% end %>
              <% else %>
                <p class="text-center py-4 opacity-50">No downvotes yet</p>
              <% end %>
            <% end %>
          </div>

          <div class="modal-action">
            <button phx-click="close_voters" class="btn btn-ghost">Close</button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="close_voters"></div>
      </div>
    <% end %>

    <!-- User Moderation Status Modal -->
    <%= if @show_user_mod_status_modal && (@is_moderator || @current_user.is_admin) && @mod_status_target_user do %>
      <div class="modal modal-open">
        <div class="modal-box modal-surface max-w-3xl">
          <div class="flex justify-between items-center mb-6">
            <h3 class="font-bold text-lg">User Moderation Status</h3>
            <button
              type="button"
              phx-click="close_user_mod_status"
              class="btn btn-ghost btn-sm btn-circle"
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>

          <div class="flex flex-col items-center gap-3 mb-6 p-4 bg-base-200 rounded-lg">
            <.user_avatar user={@mod_status_target_user} size="lg" />
            <div class="text-center">
              <div class="font-medium text-base">
                <.username_with_effects
                  user={@mod_status_target_user}
                  display_name={true}
                  verified_size="sm"
                />
              </div>
              <div class="text-sm opacity-70">
                @{@mod_status_target_user.handle || @mod_status_target_user.username}
              </div>
            </div>
          </div>

          <% mod_data = Map.get(@user_mod_data, @mod_status_target_user.id, %{}) %>
          
    <!-- Current Restrictions -->
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4 mb-6">
            <!-- Ban Status -->
            <div class={[
              "card panel-card border-2",
              if(mod_data[:ban], do: "border-error", else: "border-base-300")
            ]}>
              <div class="card-body p-4">
                <div class="flex items-center justify-between mb-2">
                  <h4 class="font-semibold flex items-center gap-2">
                    <.icon name="hero-no-symbol" class="w-4 h-4" /> Ban Status
                  </h4>
                  <%= if mod_data[:ban] do %>
                    <div class="badge badge-error">Banned</div>
                  <% else %>
                    <div class="badge badge-ghost">Not Banned</div>
                  <% end %>
                </div>
                <%= if mod_data[:ban] do %>
                  <div class="text-sm space-y-1 mb-3">
                    <div class="opacity-70">Reason: {mod_data[:ban].reason}</div>
                    <%= if mod_data[:ban].expires_at do %>
                      <div class="opacity-70">
                        Expires:
                        <.local_time
                          datetime={mod_data[:ban].expires_at}
                          format="relative"
                          timezone={@timezone}
                          time_format={@time_format}
                        />
                      </div>
                    <% else %>
                      <div class="opacity-70">Permanent ban</div>
                    <% end %>
                  </div>
                  <button
                    phx-click="unban_from_status"
                    phx-value-user_id={@mod_status_target_user.id}
                    class="btn btn-success btn-sm w-full"
                  >
                    <.icon name="hero-check" class="w-4 h-4 mr-1" /> Unban User
                  </button>
                <% else %>
                  <p class="text-sm opacity-50">No active ban</p>
                <% end %>
              </div>
            </div>
            
    <!-- Timeout Status -->
            <div class={[
              "card panel-card border-2",
              if(mod_data[:timeout], do: "border-warning", else: "border-base-300")
            ]}>
              <div class="card-body p-4">
                <div class="flex items-center justify-between mb-2">
                  <h4 class="font-semibold flex items-center gap-2">
                    <.icon name="hero-clock" class="w-4 h-4" /> Timeout Status
                  </h4>
                  <%= if mod_data[:timeout] do %>
                    <div class="badge badge-warning">Timed Out</div>
                  <% else %>
                    <div class="badge badge-ghost">Not Timed Out</div>
                  <% end %>
                </div>
                <%= if mod_data[:timeout] do %>
                  <div class="text-sm space-y-1 mb-3">
                    <div class="opacity-70">Reason: {mod_data[:timeout].reason}</div>
                    <div class="opacity-70">
                      Expires:
                      <.local_time
                        datetime={mod_data[:timeout].timeout_until}
                        format="relative"
                        timezone={@timezone}
                        time_format={@time_format}
                      />
                    </div>
                  </div>
                  <button
                    phx-click="remove_timeout_from_status"
                    phx-value-user_id={@mod_status_target_user.id}
                    class="btn btn-success btn-sm w-full"
                  >
                    <.icon name="hero-check" class="w-4 h-4 mr-1" /> Remove Timeout
                  </button>
                <% else %>
                  <p class="text-sm opacity-50">No active timeout</p>
                <% end %>
              </div>
            </div>
          </div>
          
    <!-- Warnings -->
          <div class={[
            "card panel-card border-2 mb-4",
            if(mod_data[:warning_count] && mod_data[:warning_count] > 0,
              do: "border-info",
              else: "border-base-300"
            )
          ]}>
            <div class="card-body p-4">
              <div class="flex items-center justify-between mb-3">
                <h4 class="font-semibold flex items-center gap-2">
                  <.icon name="hero-exclamation-triangle" class="w-4 h-4" /> Warnings
                </h4>
                <div class={[
                  "badge",
                  if(mod_data[:warning_count] && mod_data[:warning_count] >= 3,
                    do: "badge-error",
                    else: "badge-info"
                  )
                ]}>
                  {mod_data[:warning_count] || 0} Warning{if mod_data[:warning_count] != 1, do: "s"}
                </div>
              </div>
              <%= if mod_data[:warnings] && length(mod_data[:warnings]) > 0 do %>
                <div class="space-y-2 max-h-48 overflow-y-auto">
                  <%= for warning <- Enum.take(mod_data[:warnings], 5) do %>
                    <div class="bg-base-200 p-3 rounded-lg text-sm">
                      <div class="flex items-center gap-2 mb-1">
                        <% severity_class =
                          case warning.severity do
                            "high" -> "badge-error"
                            "medium" -> "badge-warning"
                            _ -> "badge-info"
                          end %>
                        <div class={["badge badge-xs", severity_class]}>
                          {String.upcase(warning.severity)}
                        </div>
                        <span class="opacity-70">
                          <.local_time
                            datetime={warning.inserted_at}
                            format="relative"
                            timezone={@timezone}
                            time_format={@time_format}
                          />
                        </span>
                      </div>
                      <p>{warning.reason}</p>
                    </div>
                  <% end %>
                </div>
              <% else %>
                <p class="text-sm opacity-50">No warnings</p>
              <% end %>
            </div>
          </div>
          
    <!-- Moderator Notes Preview -->
          <div class="card panel-card border-2 border-base-300 mb-4">
            <div class="card-body p-4">
              <h4 class="font-semibold flex items-center gap-2 mb-3">
                <.icon name="hero-document-text" class="w-4 h-4" />
                Moderator Notes ({length(mod_data[:notes] || [])})
              </h4>
              <%= if mod_data[:notes] && length(mod_data[:notes]) > 0 do %>
                <div class="space-y-2 max-h-48 overflow-y-auto">
                  <%= for note <- Enum.take(mod_data[:notes], 3) do %>
                    <div class={[
                      "bg-base-200 p-3 rounded-lg text-sm",
                      if(note.is_important, do: "border-l-4 border-warning")
                    ]}>
                      <%= if note.is_important do %>
                        <div class="badge badge-warning badge-xs mb-1">Important</div>
                      <% end %>
                      <p class="mb-1">{note.note}</p>
                      <div class="opacity-60 text-xs">
                        By @{note.created_by.handle || note.created_by.username}
                      </div>
                    </div>
                  <% end %>
                </div>
                <%= if length(mod_data[:notes]) > 3 do %>
                  <div class="text-xs opacity-50 mt-2">
                    And {length(mod_data[:notes]) - 3} more...
                  </div>
                <% end %>
              <% else %>
                <p class="text-sm opacity-50">No moderator notes</p>
              <% end %>
            </div>
          </div>

          <div class="modal-action justify-center">
            <button phx-click="close_user_mod_status" class="btn btn-ghost">Close</button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="close_user_mod_status"></div>
      </div>
    <% end %>

    <!-- Moderator Note Modal -->
    <%= if @show_note_modal && (@is_moderator || @current_user.is_admin) && @note_target_user do %>
      <div class="modal modal-open">
        <div class="modal-box modal-surface max-w-2xl">
          <div class="flex justify-between items-center mb-6">
            <h3 class="font-bold text-lg">Moderator Notes</h3>
            <button type="button" phx-click="cancel_note" class="btn btn-ghost btn-sm btn-circle">
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>

          <div class="flex items-center justify-center gap-3 mb-6 p-4 bg-base-200 rounded-lg">
            <.user_avatar user={@note_target_user} size="md" />
            <div class="text-center">
              <div class="font-medium">
                <.username_with_effects
                  user={@note_target_user}
                  display_name={true}
                  verified_size="sm"
                />
              </div>
              <div class="text-sm opacity-70">
                @{@note_target_user.handle || @note_target_user.username}
              </div>
            </div>
          </div>

          <div class="divider my-6">Add New Note</div>

          <.form for={%{}} phx-submit="add_moderator_note" class="mb-6">
            <input type="hidden" name="user_id" value={@note_target_user.id} />

            <div class="form-control w-full mb-4">
              <label class="label">
                <span class="label-text font-medium">Note Text</span>
              </label>
              <textarea
                name="note"
                placeholder="Add a private note about this user (visible only to moderators)..."
                class="textarea textarea-bordered w-full"
                rows="3"
                required
              ></textarea>
            </div>

            <div class="form-control w-full mb-4">
              <label class="label cursor-pointer justify-center gap-2">
                <input
                  type="checkbox"
                  name="is_important"
                  class="checkbox checkbox-warning checkbox-sm"
                />
                <span class="label-text">Mark as important</span>
              </label>
            </div>

            <div class="flex justify-center">
              <button type="submit" class="btn btn-secondary">
                <.icon name="hero-plus" class="w-4 h-4 mr-2" /> Add Note
              </button>
            </div>
          </.form>

          <div class="divider my-6">Existing Notes</div>

          <div class="space-y-3 max-h-64 overflow-y-auto">
            <%= if Map.get(@user_notes, @note_target_user.id, []) != [] do %>
              <%= for note <- Map.get(@user_notes, @note_target_user.id, []) do %>
                <div class={"card panel-card border-2 p-4 #{if note.is_important, do: "border-warning", else: "border-base-300"}"}>
                  <%= if note.is_important do %>
                    <div class="badge badge-warning badge-sm mb-3">Important</div>
                  <% end %>
                  <p class="text-sm mb-3 leading-relaxed">{note.note}</p>
                  <div class="flex justify-between items-center text-xs opacity-60">
                    <span>@{note.created_by.handle || note.created_by.username}</span>
                    <span>
                      <.local_time
                        datetime={note.inserted_at}
                        format="relative"
                        timezone={@timezone}
                        time_format={@time_format}
                      />
                    </span>
                  </div>
                </div>
              <% end %>
            <% else %>
              <p class="text-center py-8 opacity-50 text-sm">No notes yet</p>
            <% end %>
          </div>

          <div class="modal-action justify-center">
            <button phx-click="cancel_note" class="btn btn-ghost">Close</button>
          </div>
        </div>
        <div class="modal-backdrop" phx-click="cancel_note"></div>
      </div>
    <% end %>

    <!-- Timeout Modal -->
    <%= if @show_timeout_modal && (@is_moderator || @current_user.is_admin) && @timeout_target_user do %>
      <div class="modal modal-open">
        <div class="modal-box modal-surface max-w-md">
          <div class="flex justify-between items-center mb-6">
            <h3 class="font-bold text-lg">Timeout User</h3>
            <button type="button" phx-click="cancel_timeout" class="btn btn-ghost btn-sm btn-circle">
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>

          <div class="flex flex-col items-center gap-3 mb-6 p-4 bg-base-200 rounded-lg">
            <.user_avatar user={@timeout_target_user} size="lg" />
            <div class="text-center">
              <div class="font-medium text-base">
                <.username_with_effects
                  user={@timeout_target_user}
                  display_name={true}
                  verified_size="sm"
                />
              </div>
              <div class="text-sm opacity-70">
                @{@timeout_target_user.handle || @timeout_target_user.username}
              </div>
            </div>
          </div>

          <div class="alert alert-info mb-6">
            <.icon name="hero-information-circle" class="w-5 h-5" />
            <span class="text-sm">User will be unable to post but can still view content</span>
          </div>

          <.form for={%{}} phx-submit="timeout_user">
            <input type="hidden" name="user_id" value={@timeout_target_user.id} />

            <div class="form-control w-full mb-4">
              <label class="label">
                <span class="label-text font-medium">Duration</span>
              </label>
              <select name="duration_minutes" class="select select-bordered w-full">
                <option value="5">5 Minutes</option>
                <option value="30">30 Minutes</option>
                <option value="60">1 Hour</option>
                <option value="360">6 Hours</option>
                <option value="720">12 Hours</option>
                <option value="1440">1 Day</option>
                <option value="4320">3 Days</option>
                <option value="10080">7 Days</option>
              </select>
            </div>

            <div class="form-control w-full mb-6">
              <label class="label">
                <span class="label-text font-medium">Reason</span>
              </label>
              <textarea
                name="reason"
                placeholder="Explain why this timeout is being issued..."
                class="textarea textarea-bordered w-full"
                rows="3"
                required
              ></textarea>
            </div>

            <div class="modal-action justify-center gap-3">
              <button type="button" phx-click="cancel_timeout" class="btn btn-ghost">Cancel</button>
              <button type="submit" class="btn btn-warning">
                <.icon name="hero-clock" class="w-4 h-4 mr-2" /> Timeout User
              </button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="cancel_timeout"></div>
      </div>
    <% end %>

    <!-- Warning Modal -->
    <%= if @show_warning_modal && (@is_moderator || @current_user.is_admin) && @warning_target_user do %>
      <div class="modal modal-open">
        <div class="modal-box modal-surface max-w-md">
          <h3 class="font-bold text-lg mb-6 text-center text-warning">Warn User</h3>

          <div class="flex flex-col items-center gap-3 mb-6 p-4 bg-base-200 rounded-lg">
            <.user_avatar user={@warning_target_user} size="lg" />
            <div class="text-center">
              <div class="font-medium text-base">
                <.username_with_effects
                  user={@warning_target_user}
                  display_name={true}
                  verified_size="sm"
                />
              </div>
              <div class="text-sm opacity-70">
                @{@warning_target_user.handle || @warning_target_user.username}
              </div>
            </div>
          </div>

          <div class="alert alert-info mb-6">
            <.icon name="hero-information-circle" class="w-5 h-5" />
            <span class="text-sm">3 warnings will result in automatic 7-day ban</span>
          </div>

          <.form for={%{}} phx-submit="warn_user">
            <input type="hidden" name="user_id" value={@warning_target_user.id} />
            <%= if @warning_message_id do %>
              <input type="hidden" name="message_id" value={@warning_message_id} />
            <% end %>

            <div class="form-control w-full mb-4">
              <label class="label">
                <span class="label-text font-medium">Warning Severity</span>
              </label>
              <select name="severity" class="select select-bordered w-full">
                <option value="low" selected>Low</option>
                <option value="medium">Medium</option>
                <option value="high">High</option>
              </select>
            </div>

            <div class="form-control w-full mb-6">
              <label class="label">
                <span class="label-text font-medium">Warning Reason</span>
              </label>
              <textarea
                name="reason"
                placeholder="Explain why this warning is being issued..."
                class="textarea textarea-bordered w-full"
                rows="3"
                required
              ></textarea>
            </div>

            <div class="modal-action justify-center gap-3">
              <button type="button" phx-click="cancel_warning" class="btn btn-ghost">Cancel</button>
              <button type="submit" class="btn btn-warning">
                <.icon name="hero-exclamation-triangle" class="w-4 h-4 mr-2" /> Issue Warning
              </button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="cancel_warning"></div>
      </div>
    <% end %>

    <!-- Auto-Mod Rule Modal -->
    <%= if @show_rule_modal && (@is_moderator || @current_user.is_admin) do %>
      <div class="modal modal-open">
        <div class="modal-box modal-surface max-w-lg">
          <h3 class="font-bold text-lg mb-6 text-center">Add Auto-Mod Rule</h3>

          <.form for={%{}} phx-submit="create_automod_rule">
            <div class="form-control w-full mb-4">
              <label class="label">
                <span class="label-text font-medium">Rule Name</span>
              </label>
              <input
                type="text"
                name="name"
                placeholder="Spam Filter"
                class="input input-bordered w-full"
                required
              />
            </div>

            <div class="form-control w-full mb-4">
              <label class="label">
                <span class="label-text font-medium">Rule Type</span>
              </label>
              <select name="rule_type" class="select select-bordered w-full" required>
                <option value="keyword">Keyword Match</option>
                <option value="link_domain">Link Domain</option>
              </select>
            </div>

            <div class="form-control w-full mb-4">
              <label class="label">
                <span class="label-text font-medium">Pattern</span>
              </label>
              <input
                type="text"
                name="pattern"
                placeholder="spam, scam, phishing"
                class="input input-bordered w-full"
                required
              />
              <label class="label">
                <span class="label-text-alt opacity-70">Comma-separated for keywords/domains</span>
              </label>
            </div>

            <div class="form-control w-full mb-6">
              <label class="label">
                <span class="label-text font-medium">Action</span>
              </label>
              <select name="action" class="select select-bordered w-full" required>
                <option value="flag">Flag for Review</option>
                <option value="hold_for_review">Hold for Approval</option>
                <option value="remove">Auto-Remove</option>
              </select>
            </div>

            <div class="modal-action justify-center gap-3">
              <button type="button" phx-click="cancel_automod_rule" class="btn btn-ghost">
                Cancel
              </button>
              <button type="submit" class="btn btn-secondary">
                <.icon name="hero-plus" class="w-4 h-4 mr-2" /> Create Rule
              </button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="cancel_automod_rule"></div>
      </div>
    <% end %>

    <!-- Ban User Modal -->
    <%= if @show_ban_modal && (@is_moderator || @current_user.is_admin) && @ban_target_user do %>
      <div class="modal modal-open">
        <div class="modal-box modal-surface max-w-md">
          <h3 class="font-bold text-lg mb-6 text-center text-error">Ban User from Community</h3>

          <div class="flex flex-col items-center gap-3 mb-6 p-4 bg-base-200 rounded-lg">
            <.user_avatar user={@ban_target_user} size="lg" />
            <div class="text-center">
              <div class="font-medium text-base">
                <.username_with_effects
                  user={@ban_target_user}
                  display_name={true}
                  verified_size="sm"
                />
              </div>
              <div class="text-sm opacity-70">
                @{@ban_target_user.handle || @ban_target_user.username}
              </div>
            </div>
          </div>

          <div class="alert alert-warning mb-6">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span class="text-sm">
              This will prevent the user from viewing or participating in this community.
            </span>
          </div>

          <.form for={%{}} phx-submit="ban_user">
            <input type="hidden" name="user_id" value={@ban_target_user.id} />

            <div class="form-control w-full mb-4">
              <label class="label">
                <span class="label-text font-medium">Ban Reason</span>
              </label>
              <textarea
                name="reason"
                placeholder="Explain why this user is being banned..."
                class="textarea textarea-bordered w-full"
                rows="3"
                required
              ></textarea>
            </div>

            <div class="form-control w-full mb-6">
              <label class="label">
                <span class="label-text font-medium">Ban Duration</span>
              </label>
              <select name="duration_days" class="select select-bordered w-full">
                <option value="1">1 Day</option>
                <option value="3">3 Days</option>
                <option value="7">7 Days</option>
                <option value="14">14 Days</option>
                <option value="30">30 Days</option>
                <option value="0" selected>Permanent</option>
              </select>
            </div>

            <div class="modal-action justify-center gap-3">
              <button type="button" phx-click="cancel_ban" class="btn btn-ghost">Cancel</button>
              <button type="submit" class="btn btn-secondary">
                <.icon name="hero-no-symbol" class="w-4 h-4 mr-2" /> Ban User
              </button>
            </div>
          </.form>
        </div>
        <div class="modal-backdrop" phx-click="cancel_ban"></div>
      </div>
    <% end %>

    <!-- Media Upload Modal -->
    <%= if @show_image_upload_modal && @current_user do %>
      <div class="modal modal-open">
        <div class="modal-box modal-surface max-w-2xl">
          <h3 class="font-bold text-lg mb-4">Add Media to Post</h3>

          <.form
            for={%{}}
            phx-submit="upload_discussion_images"
            phx-change="validate_discussion_upload"
          >
            <!-- Media Upload Area -->
            <div class="form-control w-full mb-4">
              <label
                for={@uploads.discussion_attachments.ref}
                class="block border-2 border-dashed border-base-300 rounded-lg p-8 text-center cursor-pointer hover:border-secondary transition-colors"
              >
                <.live_file_input upload={@uploads.discussion_attachments} class="hidden" />
                <%= if Enum.empty?(@uploads.discussion_attachments.entries) do %>
                  <.icon name="hero-photo" class="w-12 h-12 mx-auto opacity-30 mb-2" />
                  <p class="text-sm opacity-70">Click to upload or drag and drop</p>
                  <p class="text-xs opacity-50 mt-1">Images: JPG, PNG, GIF, WEBP</p>
                  <p class="text-xs opacity-50">Videos: MP4, WEBM, OGV, MOV | Audio: MP3, WAV</p>
                  <p class="text-xs opacity-50 mt-1">Up to 4 files, 50MB each</p>
                <% else %>
                  <div class="space-y-4">
                    <%= for {entry, idx} <- Enum.with_index(@uploads.discussion_attachments.entries) do %>
                      <div class="border border-base-300 rounded-lg p-3">
                        <div class="flex gap-3">
                          <.live_img_preview
                            entry={entry}
                            class="rounded-lg w-24 h-24 object-cover flex-shrink-0"
                          />
                          <div class="flex-1 min-w-0">
                            <div class="text-sm font-medium mb-2 truncate">{entry.client_name}</div>
                            <input
                              type="text"
                              name={"alt_text_#{idx}"}
                              placeholder="Add description (optional)"
                              class="input input-bordered input-sm w-full"
                              maxlength="1000"
                            />
                            <div class="text-xs opacity-60 mt-1">
                              Helps visually impaired users understand the content
                            </div>
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </label>
              <%= for entry <- @uploads.discussion_attachments.entries do %>
                <%= for err <- upload_errors(@uploads.discussion_attachments, entry) do %>
                  <div class="alert alert-error mt-2">
                    <span class="text-sm">{error_to_string(err)}</span>
                  </div>
                <% end %>
              <% end %>
            </div>

            <div class="modal-action">
              <button type="button" class="btn" phx-click="close_image_upload">Cancel</button>
              <button
                type="submit"
                class="btn btn-secondary"
                disabled={Enum.empty?(@uploads.discussion_attachments.entries)}
              >
                <.icon name="hero-check" class="w-4 h-4 mr-1" /> Add Media
              </button>
            </div>
          </.form>
        </div>
      </div>
    <% end %>

    <!-- Image Modal -->
    <.image_modal
      show={@show_image_modal}
      image_url={@modal_image_url}
      images={@modal_images}
      image_index={@modal_image_index}
      post={@modal_post}
      timezone={@timezone}
      time_format={@time_format}
      current_user={@current_user}
      is_liked={@modal_post && Map.get(@user_likes || %{}, @modal_post.id, false)}
      like_count={(@modal_post && @modal_post.like_count) || 0}
    />
    """
  end

  defp error_to_string(:too_large), do: "Image is too large (max 10MB)"

  defp error_to_string(:not_accepted),
    do: "Invalid file type. Please upload JPG, PNG, GIF, or WEBP"

  defp error_to_string(:too_many_files), do: "Maximum 4 images allowed"
  defp error_to_string(_), do: "Upload error"

  defp display_discussion_title(post) do
    case Map.get(post, :title) do
      title when is_binary(title) ->
        title = plain_text_content(title)
        if Elektrine.Strings.present?(title), do: title, else: "Untitled discussion"

      _ ->
        "Untitled discussion"
    end
  end

  defp has_explicit_discussion_title?(post) do
    case Map.get(post, :title) do
      title when is_binary(title) -> Elektrine.Strings.present?(title)
      _ -> false
    end
  end

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

    if Elektrine.Strings.present?(community.description) do
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
      Elektrine.Strings.present?(banner) ->
        Elektrine.Uploads.attachment_url(banner)

      Elektrine.Strings.present?(avatar) ->
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
