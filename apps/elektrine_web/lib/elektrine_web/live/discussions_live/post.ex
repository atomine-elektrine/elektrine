defmodule ElektrineWeb.DiscussionsLive.Post do
  use ElektrineWeb, :live_view
  import Ecto.Query
  import ElektrineWeb.Components.Social.ContentJourney
  import ElektrineWeb.Components.Social.Poll
  import ElektrineWeb.Components.Social.PostActions
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.Live.NotificationHelpers
  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.Social.EmbeddedPost
  import ElektrineWeb.HtmlHelpers

  alias Elektrine.{Messaging, Social}
  alias ElektrineWeb.DiscussionsLive.PostRouter

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns[:current_user]

    # Extract post_id from either direct ID or slug
    post_id =
      case params do
        %{"post_id" => id} ->
          # Handle both integer IDs and slug format "123-title"
          case Integer.parse(id) do
            # Extract integer from slug
            {int_id, _} -> int_id
            :error -> nil
          end

        %{"post_slug" => slug} ->
          case Elektrine.Utils.Slug.extract_post_id_from_slug(slug) do
            nil -> nil
            id -> id
          end

        _ ->
          nil
      end

    community_name = params["name"]

    if post_id == nil do
      {:ok,
       socket
       |> notify_error("Invalid discussion link")
       |> push_navigate(to: ~p"/communities")}
    else
      # Find community by name or hash
      community =
        Elektrine.Repo.get_by(Elektrine.Messaging.Conversation,
          name: community_name,
          type: "community"
        ) ||
          Elektrine.Repo.get_by(Elektrine.Messaging.Conversation,
            hash: community_name,
            type: "community"
          )

      community_id = if community, do: community.id, else: nil

      if community_id do
        # For public communities, we don't require membership
        community =
          Elektrine.Repo.get_by(Elektrine.Messaging.Conversation,
            id: community_id,
            type: "community"
          )

        if community do
          # Check if user has access (member of private community or any user for public)
          has_access =
            if community.is_public do
              true
            else
              # Check membership for private communities
              Elektrine.Repo.exists?(
                from cm in Elektrine.Messaging.ConversationMember,
                  where:
                    cm.conversation_id == ^community_id and
                      cm.user_id == ^user.id and
                      is_nil(cm.left_at)
              )
            end

          if has_access do
            # Get the main post
            case get_post_with_replies(post_id, community_id) do
              {:ok, post, replies} ->
                if connected?(socket) do
                  Phoenix.PubSub.subscribe(Elektrine.PubSub, "conversation:#{community_id}")
                  # Subscribe to message-specific updates for likes
                  Phoenix.PubSub.subscribe(Elektrine.PubSub, "message:#{post_id}")
                end

                # Get related posts
                related_posts =
                  Social.get_related_discussion_posts(community_id, post_id, limit: 5)
                  |> Enum.map(&Elektrine.Messaging.Message.decrypt_content/1)

                # Check if user is a moderator
                is_moderator =
                  if user do
                    member = Messaging.get_conversation_member(community_id, user.id)
                    member && member.role in ["moderator", "admin", "owner"]
                  else
                    false
                  end

                # Check if post is approved - hide from non-moderators if not
                if post.approval_status not in ["approved", nil] && !is_moderator do
                  {:ok,
                   socket
                   |> notify_error("This post is not available")
                   |> push_navigate(to: ~p"/communities/#{community.name}")}
                else
                  # Build metadata for sharing
                  meta_description = build_post_description(post, community)
                  og_image = get_post_image(post)
                  slug = Elektrine.Utils.Slug.discussion_url_slug(post_id, post.title)

                  current_url =
                    "#{ElektrineWeb.Endpoint.url()}/discussions/#{community.name}/post/#{slug}"

                  # Track view for recommendation algorithm
                  if user do
                    Social.track_post_view(user.id, post.id)
                  end

                  # Load reactions for the post
                  post_reactions = load_post_reactions(post.id)

                  # Load user's votes for all posts and replies
                  user_votes =
                    if user do
                      # Replies are threaded maps with :reply key containing the actual message
                      reply_ids = collect_all_reply_ids(replies)
                      all_message_ids = [post.id | reply_ids]
                      Social.get_user_votes(user.id, all_message_ids)
                    else
                      %{}
                    end

                  community_slug =
                    String.downcase(community.name) |> String.replace(~r/[^a-z0-9]+/, "-")

                  {:ok,
                   socket
                   |> assign(:page_title, "#{post.title || "Discussion"} in !#{community_slug}")
                   |> assign(:post_reactions, post_reactions)
                   |> assign(:user_votes, user_votes)
                   |> assign(:community_slug, community_slug)
                   |> assign(:meta_description, meta_description)
                   |> assign(:og_image, og_image)
                   |> assign(:current_url, current_url)
                   |> assign(:community, community)
                   |> assign(:post, post)
                   |> assign(:replies, replies)
                   |> assign(:related_posts, related_posts)
                   |> assign(:is_moderator, is_moderator)
                   |> assign(:reply_content, "")
                   |> assign(:show_reply_form, false)
                   |> assign(:nested_reply_to, nil)
                   |> assign(:nested_reply_content, "")
                   |> assign(:show_report_modal, false)
                   |> assign(:liked_by_user, user && Social.user_liked_post?(user.id, post_id))
                   |> assign(:report_type, nil)
                   |> assign(:report_id, nil)
                   |> assign(:report_metadata, %{})
                   |> assign(:available_conversations, [])
                   |> assign(:show_ban_modal, false)
                   |> assign(:ban_target_user, nil)
                   |> assign(:show_warning_modal, false)
                   |> assign(:warning_target_user, nil)
                   |> assign(:warning_message_id, nil)
                   |> assign(:show_timeout_modal, false)
                   |> assign(:timeout_target_user, nil)
                   |> assign(:show_note_modal, false)
                   |> assign(:note_target_user, nil)
                   |> assign(:user_notes, %{})
                   |> assign(:show_user_mod_status_modal, false)
                   |> assign(:mod_status_target_user, nil)
                   |> assign(:user_mod_data, %{})
                   |> assign(:expanded_threads, MapSet.new())
                   |> assign(:show_image_modal, false)
                   |> assign(:modal_image_url, nil)
                   |> assign(:modal_images, [])
                   |> assign(:modal_image_index, 0)
                   |> assign(:modal_post, nil)}
                end

              {:error, :not_found} ->
                {:ok,
                 socket
                 |> notify_error("Discussion post not found")
                 |> push_navigate(to: ~p"/communities/#{community.name}")}
            end
          else
            {:ok,
             socket
             |> notify_error("You must be a member of this community to view its discussions")
             |> push_navigate(to: ~p"/communities")}
          end
        else
          {:ok,
           socket
           |> notify_error("Community not found")
           |> push_navigate(to: ~p"/communities")}
        end
      else
        {:ok,
         socket
         |> notify_error("Community not found")
         |> push_navigate(to: ~p"/communities")}
      end
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event(event_name, params, socket) do
    PostRouter.route_event(event_name, params, socket)
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

  defp get_post_with_replies(post_id, community_id) do
    get_post_with_replies_expanded(post_id, community_id, MapSet.new())
  end

  defp get_post_with_replies_expanded(post_id, community_id, expanded_threads) do
    import Ecto.Query

    # Get the main post
    post =
      from(m in Elektrine.Messaging.Message,
        where: m.id == ^post_id and m.conversation_id == ^community_id,
        preload: [
          sender: [:profile],
          link_preview: [],
          flair: [],
          shared_message: [sender: [:profile], conversation: []],
          poll: [options: []]
        ]
      )
      |> Elektrine.Repo.one()

    case post do
      nil ->
        {:error, :not_found}

      post ->
        # Decrypt post content
        post = Elektrine.Messaging.Message.decrypt_content(post)

        # Get all replies in a threaded structure
        replies = get_threaded_replies_with_expansion(post_id, community_id, 0, expanded_threads)
        {:ok, post, replies}
    end
  end

  defp get_threaded_replies_with_expansion(parent_id, community_id, depth, expanded_threads) do
    import Ecto.Query

    # Get direct replies to this parent
    direct_replies =
      from(m in Elektrine.Messaging.Message,
        where:
          m.reply_to_id == ^parent_id and
            m.conversation_id == ^community_id and
            is_nil(m.deleted_at) and
            (m.approval_status == "approved" or is_nil(m.approval_status)),
        order_by: [desc: m.score, asc: m.inserted_at],
        preload: [
          sender: [:profile],
          flair: [],
          shared_message: [sender: [:profile], conversation: []]
        ]
      )
      |> Elektrine.Repo.all()
      |> Enum.map(&Elektrine.Messaging.Message.decrypt_content/1)

    # For each reply, get its nested replies (recursive)
    Enum.map(direct_replies, fn reply ->
      # Check if we should expand this reply's children
      # Either we're within initial depth (< 2) OR this specific reply is in expanded set
      should_expand = depth < 2 || MapSet.member?(expanded_threads, reply.id)

      # Hard limit at 10 to prevent infinite recursion
      nested_replies =
        if should_expand && depth < 10 do
          get_threaded_replies_with_expansion(reply.id, community_id, depth + 1, expanded_threads)
        else
          []
        end

      %{reply: reply, children: nested_replies, depth: depth, has_children: should_expand}
    end)
  end

  def format_post_content(content) when is_binary(content) do
    content
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> make_links_clickable()
    |> format_content_with_paragraphs()
  end

  def format_post_content(_), do: ""

  defp make_links_clickable(text) when is_binary(text) do
    text
    |> make_content_safe_with_links()
    |> preserve_line_breaks()
  end

  defp make_links_clickable(_), do: ""

  defp format_relative_time(%NaiveDateTime{} = naive_dt) do
    datetime = DateTime.from_naive!(naive_dt, "Etc/UTC")
    format_relative_time(datetime)
  end

  defp format_relative_time(%DateTime{} = datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      diff < 2_592_000 -> "#{div(diff, 604_800)}w ago"
      true -> "#{div(diff, 2_592_000)}mo ago"
    end
  end

  defp format_relative_time(_), do: ""

  defp format_content_with_paragraphs(text) when is_binary(text) do
    # Convert double line breaks to paragraphs, single line breaks to <br> tags
    text
    |> String.split(~r/\n\n+/)
    |> Enum.map(fn paragraph ->
      paragraph
      |> String.trim()
      |> case do
        "" ->
          ""

        text ->
          # Replace single line breaks with <br> tags within paragraphs
          formatted = String.replace(text, "\n", "<br>")
          "<p class=\"mb-2\">#{formatted}</p>"
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join()
  end

  defp format_content_with_paragraphs(_), do: ""

  defp render_user_avatar(user) do
    if user && Map.get(user, :avatar) do
      avatar_url = Elektrine.Uploads.avatar_url(user.avatar)
      handle = Map.get(user, :handle)
      username = Map.get(user, :username, "User")
      display_name = if handle, do: handle, else: username
      escaped_username = Phoenix.HTML.html_escape(display_name) |> Phoenix.HTML.safe_to_string()

      """
      <img
        src="#{avatar_url}"
        alt="#{escaped_username} avatar"
        class="w-6 h-6 rounded-lg object-cover"
      />
      """
    else
      """
      <div class="w-6 h-6 bg-gradient-to-br from-primary to-secondary text-primary-content flex items-center justify-center rounded-lg shadow-lg">
        <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"></path>
        </svg>
      </div>
      """
    end
  end

  defp has_more_replies?(message_id, community_id) do
    import Ecto.Query

    Elektrine.Repo.exists?(
      from m in Elektrine.Messaging.Message,
        where:
          m.reply_to_id == ^message_id and m.conversation_id == ^community_id and
            is_nil(m.deleted_at)
    )
  end

  def count_total_replies(threaded_replies) when is_list(threaded_replies) do
    Enum.reduce(threaded_replies, 0, fn
      %{children: children}, acc ->
        1 + acc + count_total_replies(children)

      _, acc ->
        # Handle malformed replies
        1 + acc
    end)
  end

  def count_total_replies(_), do: 0

  # Recursively collect all reply IDs from threaded replies
  defp collect_all_reply_ids(threaded_replies) when is_list(threaded_replies) do
    Enum.flat_map(threaded_replies, fn
      %{reply: reply, children: children} ->
        [reply.id | collect_all_reply_ids(children)]

      _ ->
        []
    end)
  end

  defp collect_all_reply_ids(_), do: []

  def render_threaded_replies(threaded_replies, assigns) do
    Phoenix.HTML.raw(
      Enum.map_join(threaded_replies, "", &render_single_threaded_reply(&1, assigns))
    )
  end

  defp render_single_threaded_reply(%{reply: reply, children: children, depth: depth}, assigns) do
    # Use minimal indentation and cap it early (like Reddit)
    indent_class =
      case depth do
        0 -> ""
        1 -> "ml-4"
        2 -> "ml-8"
        # Don't indent further than 2 levels
        _ -> "ml-8"
      end

    border_color =
      case depth do
        0 -> "border-l-error"
        1 -> "border-l-secondary"
        2 -> "border-l-accent"
        3 -> "border-l-info"
        _ -> "border-l-base-300"
      end

    line_color =
      case depth do
        0 -> "bg-error"
        1 -> "bg-secondary"
        2 -> "bg-accent"
        3 -> "bg-info"
        _ -> "bg-base-300"
      end

    children_html =
      if children != [] do
        Enum.map_join(children, "", &render_single_threaded_reply(&1, assigns))
      else
        ""
      end

    # Escape all user-controlled data
    escaped_username =
      Phoenix.HTML.html_escape(reply.sender.handle || reply.sender.username)
      |> Phoenix.HTML.safe_to_string()

    escaped_content = Phoenix.HTML.html_escape(reply.content) |> Phoenix.HTML.safe_to_string()
    escaped_content_with_links = make_links_clickable(escaped_content)

    # Build flair HTML if flair exists and is loaded
    flair_html =
      if reply.flair_id && Ecto.assoc_loaded?(reply.flair) do
        flair_name = Phoenix.HTML.html_escape(reply.flair.name) |> Phoenix.HTML.safe_to_string()

        flair_background_color =
          Phoenix.HTML.html_escape(reply.flair.background_color) |> Phoenix.HTML.safe_to_string()

        flair_text_color =
          Phoenix.HTML.html_escape(reply.flair.text_color) |> Phoenix.HTML.safe_to_string()

        """
        <span class="badge badge-sm ml-1" style="background-color: #{flair_background_color}; color: #{flair_text_color}">
          #{flair_name}
        </span>
        """
      else
        ""
      end

    # Check if user is authenticated for voting buttons
    user_votes = Map.get(assigns, :user_votes, %{})
    user_vote = Map.get(user_votes, reply.id)

    # Calculate score and text color
    score = (reply.upvotes || 0) - (reply.downvotes || 0)

    score_class =
      cond do
        user_vote == "up" -> "text-secondary"
        user_vote == "down" -> "text-error"
        true -> ""
      end

    voting_html =
      if Map.get(assigns, :current_user) do
        upvote_class =
          if user_vote == "up",
            do: "bg-secondary/20 text-secondary hover:bg-secondary/30",
            else: "btn-ghost hover:bg-secondary/20 hover:text-secondary"

        downvote_class =
          if user_vote == "down",
            do: "bg-error/20 text-error hover:bg-error/30",
            else: "btn-ghost hover:bg-error/20 hover:text-error"

        upvote_svg =
          if user_vote == "up",
            do:
              ~s(<svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24"><path d="M12 4l-8 8h5v8h6v-8h5z"></path></svg>),
            else:
              ~s(<svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 15l7-7 7 7"></path></svg>)

        downvote_svg =
          if user_vote == "down",
            do:
              ~s(<svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24"><path d="M12 20l8-8h-5V4H9v8H4z"></path></svg>),
            else:
              ~s(<svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"></path></svg>)

        """
        <button
          phx-click="vote"
          phx-value-message_id="#{reply.id}"
          phx-value-type="up"
          class="btn btn-xs p-1 transition-colors #{upvote_class}"
        >
          #{upvote_svg}
        </button>
        <span class="text-sm font-medium #{score_class}">
          #{score}
        </span>
        <button
          phx-click="vote"
          phx-value-message_id="#{reply.id}"
          phx-value-type="down"
          class="btn btn-xs p-1 transition-colors #{downvote_class}"
        >
          #{downvote_svg}
        </button>
        """
      else
        """
        <div class="btn btn-ghost btn-xs p-1 opacity-50 cursor-not-allowed">
          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 15l7-7 7 7"></path>
          </svg>
        </div>
        <span class="text-sm font-medium">
          #{score}
        </span>
        <div class="btn btn-ghost btn-xs p-1 opacity-50 cursor-not-allowed">
          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"></path>
          </svg>
        </div>
        """
      end

    """
    <div class="#{indent_class} relative">
      #{if depth > 0 do
      """
      <div class="absolute left-0 top-0 bottom-0 w-px #{line_color} opacity-30"></div>
      """
    else
      ""
    end}
      <div class="card bg-base-50 border border-base-200 shadow-sm border-l-4 #{border_color}">
        <div class="card-body p-4">
          <div class="flex gap-3">
            <!-- Reply Voting -->
            <div class="flex flex-col items-center gap-1">
              #{voting_html}
            </div>

            <!-- Reply Content -->
            <div class="flex-1 min-w-0">
              <!-- Reply Header -->
              <div class="flex items-center gap-2 mb-2">
                <a href="/#{escaped_username}" class="w-6 h-6">
                  #{render_user_avatar(reply.sender)}
                </a>
                <div class="flex items-center gap-1 flex-wrap">
                  <a href="/#{escaped_username}" class="inline-flex items-center font-medium text-sm hover:underline">
                    #{escaped_username}
                  </a>
                  #{flair_html}
                  #{if reply.sender_id == Map.get(assigns, :post).sender_id do
      """
      <span class="badge badge-xs badge-info">OP</span>
      """
    else
      ""
    end}
                </div>
                <span class="text-xs opacity-70">
                  · #{format_relative_time(reply.inserted_at)}
                </span>
              </div>

              <!-- Reply Content -->
              <div class="mb-3">
                <div class="text-sm break-words leading-normal">
                  #{format_content_with_paragraphs(escaped_content_with_links)}
                </div>
              </div>

              <!-- Reply Actions -->
              <div class="flex items-center gap-3 text-xs opacity-70">
                #{if Map.get(assigns, :current_user) do
      """
      <button
        phx-click="show_nested_reply_form"
        phx-value-message_id="#{reply.id}"
        class="hover:underline hover:text-error"
      >
        Reply
      </button>
      <button
        phx-click="copy_link"
        phx-value-message_id="#{reply.id}"
        class="hover:underline hover:text-error"
      >
        Share
      </button>
      #{if reply.activitypub_id do
        """
        <a
          href="#{Phoenix.HTML.html_escape(reply.activitypub_id) |> Phoenix.HTML.safe_to_string()}"
          target="_blank"
          rel="noopener noreferrer"
          class="hover:underline hover:text-error inline-flex items-center gap-1"
          title="Open on remote instance"
        >
          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"></path>
          </svg>
          Remote
        </a>
        """
      else
        ""
      end}

      <!-- Dropdown Menu for Moderators and Admins -->
      #{if (Map.get(assigns, :is_moderator) || Map.get(assigns, :current_user).is_admin) && reply.sender_id != Map.get(assigns, :current_user).id do
        """
        <div class="dropdown dropdown-end">
          <label tabindex="0" class="btn btn-ghost btn-xs">
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 5v.01M12 12v.01M12 19v.01M12 6a1 1 0 110-2 1 1 0 010 2zm0 7a1 1 0 110-2 1 1 0 010 2zm0 7a1 1 0 110-2 1 1 0 010 2z"></path>
            </svg>
          </label>
          <ul tabindex="0" class="dropdown-content z-30 menu p-2 shadow-lg bg-base-100 border border-base-300 rounded-box w-52 z-30 opacity-100">
            <li>
              <button
                phx-click="delete_reply"
                phx-value-message_id="#{reply.id}"
                class="text-error"
                data-confirm="Delete this reply?"
              >
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"></path>
                </svg>
                Delete Reply
              </button>
            </li>
            <li>
              <button
                phx-click="show_ban_modal"
                phx-value-user_id="#{reply.sender_id}"
                class="text-error"
              >
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"></path>
                </svg>
                Ban User
              </button>
            </li>
            <li>
              <button
                phx-click="show_warning_modal"
                phx-value-user_id="#{reply.sender_id}"
                phx-value-message_id="#{reply.id}"
              >
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"></path>
                </svg>
                Warn User
              </button>
            </li>
            <li>
              <button
                phx-click="show_timeout_modal"
                phx-value-user_id="#{reply.sender_id}"
              >
                <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"></path>
                </svg>
                Timeout User
              </button>
            </li>
          </ul>
        </div>
        """
      else
        ""
      end}
      """
    else
      """
      <span class="opacity-50">Sign in to interact</span>
      #{if reply.activitypub_id do
        """
        <a
          href="#{Phoenix.HTML.html_escape(reply.activitypub_id) |> Phoenix.HTML.safe_to_string()}"
          target="_blank"
          rel="noopener noreferrer"
          class="hover:underline hover:text-error inline-flex items-center gap-1"
          title="Open on remote instance"
        >
          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"></path>
          </svg>
          Remote
        </a>
        """
      else
        ""
      end}
      """
    end}
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Continue Thread Link -->
      #{if depth >= 2 && children == [] && has_more_replies?(reply.id, Map.get(assigns, :community).id) do
      """
      <div class="#{indent_class} mt-2">
        <button
          phx-click="load_more_replies"
          phx-value-parent_id="#{reply.id}"
          class="text-sm text-error hover:underline inline-flex items-center gap-1 btn btn-ghost btn-xs"
        >
          <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 5l7 7-7 7M5 5l7 7-7 7"></path>
          </svg>
          Load more replies
        </button>
      </div>
      """
    else
      ""
    end}

      <!-- Nested Reply Form -->
      #{if Map.get(assigns, :current_user) && Map.get(assigns, :nested_reply_to) == reply.id do
      """
      <div class="mt-4 #{indent_class}">
        <div class="card bg-base-200 border border-base-200 shadow-sm">
          <div class="card-body p-4">
            <div class="flex items-start gap-3 mb-3">
              <div class="w-6 h-6">
                #{render_user_avatar(Map.get(assigns, :current_user))}
              </div>
              <div class="text-sm opacity-70">
                Replying to <span class="font-medium">@#{escaped_username}</span>
              </div>
            </div>

            <form phx-submit="create_nested_reply" phx-change="update_nested_reply_content">
              <input type="hidden" name="reply_to_id" value="#{reply.id}" />
              <textarea
                name="content"
                placeholder="Write your reply..."
                class="textarea textarea-bordered w-full mb-3"
                rows="3"
                required
              >#{assigns[:nested_reply_content] || ""}</textarea>

              <div class="flex gap-2 justify-end items-center">
                <span class="text-xs #{if String.length(assigns[:nested_reply_content] || "") < 3, do: "text-error", else: "text-success"}">
                  #{String.length(assigns[:nested_reply_content] || "")}/3 min
                </span>
                <button type="button" phx-click="cancel_nested_reply" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-secondary btn-sm" #{if String.length(assigns[:nested_reply_content] || "") < 3, do: "disabled", else: ""}>
                  Reply
                </button>
              </div>
            </form>
          </div>
        </div>
      </div>
      """
    else
      ""
    end}

      #{children_html}
    </div>
    """
  end

  @impl true
  def handle_info({:liked, like}, socket) do
    # Update like count and liked status in real-time
    if like.message_id == socket.assigns.post.id do
      # Reload post to get fresh like count while preserving all associations
      updated_post =
        Elektrine.Repo.get!(Elektrine.Messaging.Message, socket.assigns.post.id)
        |> Elektrine.Repo.preload(
          sender: [:profile],
          link_preview: [],
          flair: [],
          shared_message: [sender: [:profile], conversation: []],
          poll: [options: []]
        )
        |> Elektrine.Messaging.Message.decrypt_content()

      liked_by_user =
        if socket.assigns.current_user && like.user_id == socket.assigns.current_user.id,
          do: true,
          else: socket.assigns.liked_by_user

      {:noreply,
       socket
       |> assign(:post, updated_post)
       |> assign(:liked_by_user, liked_by_user)}
    else
      # Update reply like counts if needed
      updated_replies =
        Enum.map(socket.assigns.replies, fn reply ->
          if reply.id == like.message_id do
            %{reply | like_count: (reply.like_count || 0) + 1}
          else
            reply
          end
        end)

      {:noreply, assign(socket, :replies, updated_replies)}
    end
  end

  @impl true
  def handle_info({:unliked, like}, socket) do
    # Update like count and liked status in real-time
    if like.message_id == socket.assigns.post.id do
      # Reload post to get fresh like count while preserving all associations
      updated_post =
        Elektrine.Repo.get!(Elektrine.Messaging.Message, socket.assigns.post.id)
        |> Elektrine.Repo.preload(
          sender: [:profile],
          link_preview: [],
          flair: [],
          shared_message: [sender: [:profile], conversation: []],
          poll: [options: []]
        )
        |> Elektrine.Messaging.Message.decrypt_content()

      liked_by_user =
        if socket.assigns.current_user && like.user_id == socket.assigns.current_user.id,
          do: false,
          else: socket.assigns.liked_by_user

      {:noreply,
       socket
       |> assign(:post, updated_post)
       |> assign(:liked_by_user, liked_by_user)}
    else
      # Update reply like counts if needed
      updated_replies =
        Enum.map(socket.assigns.replies, fn reply ->
          if reply.id == like.message_id do
            %{reply | like_count: max((reply.like_count || 1) - 1, 0)}
          else
            reply
          end
        end)

      {:noreply, assign(socket, :replies, updated_replies)}
    end
  end

  @impl true
  def handle_info({:message_link_preview_updated, message}, socket) do
    # The message already has the link_preview preloaded from the broadcast
    # Update the post if it's the one being viewed
    if message.id == socket.assigns.post.id do
      # Ensure all associations are loaded, not just link_preview
      updated_post =
        Elektrine.Repo.preload(
          message,
          [
            sender: [:profile],
            link_preview: [],
            flair: [],
            shared_message: [sender: [:profile], conversation: []],
            poll: [options: []]
          ],
          force: true
        )

      {:noreply, assign(socket, :post, updated_post)}
    else
      # Check if it's a reply that needs updating
      updated_replies =
        Enum.map(socket.assigns.replies, fn reply_struct ->
          if reply_struct.reply.id == message.id do
            %{reply_struct | reply: message}
          else
            reply_struct
          end
        end)

      {:noreply, assign(socket, :replies, updated_replies)}
    end
  end

  def handle_info({:new_message, message}, socket) do
    # Decrypt the new message
    message = Elektrine.Messaging.Message.decrypt_content(message)

    # Handle new replies to this post in real-time
    if message.reply_to_id == socket.assigns.post.id do
      # Check if this reply already exists in our list (to prevent duplicates)
      # This can happen if we just created the reply ourselves
      reply_exists =
        Enum.any?(socket.assigns.replies, fn %{reply: r} ->
          r.id == message.id
        end)

      if reply_exists do
        # Reply already in list, skip adding it
        {:noreply, socket}
      else
        # Convert the new message to the threaded structure
        message_with_associations = Elektrine.Repo.preload(message, sender: [:profile])

        new_reply_structure = %{
          reply: message_with_associations,
          # New replies don't have children yet
          children: [],
          depth: 0
        }

        updated_replies = [new_reply_structure | socket.assigns.replies]

        {:noreply, assign(socket, :replies, updated_replies)}
      end
    else
      # Could be a nested reply - refresh the entire thread while preserving expanded state
      if message.conversation_id == socket.assigns.community.id do
        # Always refresh for nested replies to ensure they appear, but preserve expanded threads
        {:ok, _post, updated_replies} =
          get_post_with_replies_expanded(
            socket.assigns.post.id,
            socket.assigns.community.id,
            socket.assigns.expanded_threads
          )

        {:noreply, assign(socket, :replies, updated_replies)}
      else
        {:noreply, socket}
      end
    end
  end

  # Handle member joined events from PubSub
  def handle_info({:member_joined, _data}, socket) do
    # Simply ignore member join events for discussion posts
    {:noreply, socket}
  end

  # Handle member left events from PubSub
  def handle_info({:member_left, _data}, socket) do
    # Simply ignore member leave events for discussion posts
    {:noreply, socket}
  end

  def handle_info({:thread_locked, message}, socket) do
    if message.id == socket.assigns.post.id do
      updated_post = %{
        socket.assigns.post
        | locked_at: message.locked_at,
          locked_by_id: message.locked_by_id,
          lock_reason: message.lock_reason
      }

      {:noreply, assign(socket, :post, updated_post)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:thread_unlocked, message}, socket) do
    if message.id == socket.assigns.post.id do
      updated_post = %{socket.assigns.post | locked_at: nil, locked_by_id: nil, lock_reason: nil}
      {:noreply, assign(socket, :post, updated_post)}
    else
      {:noreply, socket}
    end
  end

  # Catch-all for any unhandled messages
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Build meta description from discussion post
  defp build_post_description(post, community) do
    author = "@#{post.sender.handle || post.sender.username}"
    content = post.content || ""
    # Include author, community name and content preview
    description = "#{author} in #{community.name}: #{content}"

    # Strip to first 160 characters for meta description
    description
    |> String.trim()
    |> String.slice(0, 160)
    |> then(fn text ->
      if String.length(description) > 160, do: text <> "...", else: text
    end)
  end

  # Get image for Open Graph from link preview or media
  defp get_post_image(post) do
    cond do
      # Use link preview image if available
      match?(%Elektrine.Social.LinkPreview{}, post.link_preview) &&
        post.link_preview.status == "success" &&
          post.link_preview.image_url ->
        post.link_preview.image_url

      # Use first media URL if available
      post.media_urls && !Enum.empty?(post.media_urls) ->
        List.first(post.media_urls)

      # Extract direct image URLs from content
      true ->
        image_urls = Elektrine.Messaging.Message.extract_image_urls(post.content)

        cond do
          image_urls != [] ->
            List.first(image_urls)

          # Fallback to author's avatar
          post.sender.avatar ->
            Elektrine.Uploads.avatar_url(post.sender.avatar)

          # Final fallback to default OG image
          true ->
            nil
        end
    end
  end

  # Load reactions for a post
  defp load_post_reactions(post_id) do
    import Ecto.Query

    reactions =
      from(r in Elektrine.Messaging.MessageReaction,
        where: r.message_id == ^post_id,
        preload: [:user, :remote_actor]
      )
      |> Elektrine.Repo.all()

    %{post_id => reactions}
  end
end
