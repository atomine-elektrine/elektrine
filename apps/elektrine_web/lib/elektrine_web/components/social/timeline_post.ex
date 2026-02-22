defmodule ElektrineWeb.Components.Social.TimelinePost do
  @moduledoc """
  Unified timeline post component for rendering posts across timeline, hashtag, and other feed views.
  Supports local posts, federated posts, boosts, replies, polls, cross-posts, and all media types.

  ## Layout Variants

  The component supports different layout variants via the `:layout` attribute:

  - `:timeline` (default) - Standard social media post layout with full content
  - `:lemmy` - Reddit/Lemmy style with vote column on left, thumbnail, and compact meta
  - `:compact` - Minimal layout for dense feeds

  ## Usage

      <.timeline_post post={post} current_user={@current_user} layout={:timeline} />
      <.timeline_post post={post} current_user={@current_user} layout={:lemmy} />
  """
  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]
  import ElektrineWeb.CoreComponents
  import ElektrineWeb.HtmlHelpers
  import ElektrineWeb.Components.Social.PostActions
  import ElektrineWeb.Components.Social.EmbeddedPost, only: [embedded_post: 1]
  import ElektrineWeb.Components.Social.PostReactions, only: [post_reactions: 1]
  import ElektrineWeb.Components.Social.ContentJourney, only: [content_journey: 1]
  import ElektrineWeb.Components.User.Avatar
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.Components.User.HoverCard

  alias Elektrine.Messaging
  alias Elektrine.Social.LinkPreview
  alias ElektrineWeb.Components.Social.PostUtilities

  @doc """
  Renders a complete timeline post card.

  ## Attributes

  * `:post` - The post/message struct
  * `:current_user` - Current logged-in user (nil if not logged in)
  * `:timezone` - User's timezone for timestamp display
  * `:time_format` - Time format preference
  * `:user_likes` - Map of post_id => boolean for like status
  * `:user_boosts` - Map of post_id => boolean for boost status
  * `:user_follows` - Map of {:local|:remote, id} => boolean for follow status
  * `:pending_follows` - Map of {:remote, id} => boolean for pending follow requests
  * `:user_statuses` - Map of user statuses for presence
  * `:lemmy_counts` - Optional map of activitypub_id => counts for Lemmy posts
  * `:post_replies` - Optional map of post_id => replies for reply counts
  * `:id_prefix` - Prefix for element IDs (default: "post")
  * `:show_follow_button` - Whether to show follow button (default: true)
  * `:show_admin_actions` - Whether to show admin actions (default: true)
  * `:on_navigate_post` - Event for navigating to post detail
  * `:on_navigate_profile` - Event for navigating to profile
  * `:on_image_click` - Event for opening image modal
  * `:click_event` - Event when clicking the card (for navigation)
  * `:layout` - Layout variant: :timeline (default), :lemmy, or :compact
  * `:user_downvotes` - Map of post_id => boolean for downvote status (Lemmy layout)
  * `:post_interactions` - Map of post_id => interaction state for optimistic updates
  * `:reactions` - List of reactions on the post (Lemmy layout)
  * `:replies` - List of replies to display in thread preview (Lemmy layout)
  * `:user_saves` - Map of post_id => boolean for save status
  """
  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "12h"
  attr :layout, :atom, default: :timeline
  attr :user_likes, :map, default: %{}
  attr :user_boosts, :map, default: %{}
  attr :user_downvotes, :map, default: %{}
  attr :user_follows, :map, default: %{}
  attr :user_saves, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :user_statuses, :map, default: %{}
  attr :lemmy_counts, :map, default: %{}
  attr :post_replies, :map, default: %{}
  attr :post_interactions, :map, default: %{}
  attr :reactions, :list, default: []
  attr :replies, :list, default: []
  attr :id_prefix, :string, default: "post"
  attr :show_follow_button, :boolean, default: true
  attr :show_admin_actions, :boolean, default: true
  attr :show_view_button, :boolean, default: false
  attr :on_navigate_post, :string, default: "navigate_to_post"
  attr :on_navigate_profile, :string, default: "navigate_to_profile"
  attr :on_image_click, :string, default: "open_image_modal"
  attr :on_like, :string, default: "like_post"
  attr :on_unlike, :string, default: "unlike_post"
  attr :on_downvote, :string, default: "downvote_post"
  attr :on_undownvote, :string, default: "undownvote_post"
  attr :on_react, :string, default: "react_to_post"
  attr :click_event, :string, default: nil
  attr :source, :string, default: "timeline"
  attr :resolve_reply_refs, :boolean, default: false

  def timeline_post(assigns) do
    # Dispatch based on layout variant
    case assigns.layout do
      :lemmy -> render_lemmy_layout(assigns)
      :compact -> render_compact_layout(assigns)
      _ -> render_timeline_layout(assigns)
    end
  end

  # Standard timeline layout (default)
  defp render_timeline_layout(assigns) do
    post = assigns.post

    # Determine if this is a reply
    is_reply = PostUtilities.reply?(post)

    # Determine if this is a gallery post
    is_gallery_post = PostUtilities.gallery_post?(post)

    # Determine click event
    click_event = assigns.click_event || PostUtilities.get_post_click_event(post)

    # Calculate display counts
    {display_like_count, display_comment_count} =
      PostUtilities.get_display_counts(post, assigns.lemmy_counts, assigns.post_replies)

    assigns =
      assigns
      |> assign(:is_reply, is_reply)
      |> assign(:is_gallery_post, is_gallery_post)
      |> assign(:click_event, click_event)
      |> assign(:display_like_count, display_like_count)
      |> assign(:display_comment_count, display_comment_count)

    ~H"""
    <div
      id={"#{@id_prefix}-card-#{@post.id}"}
      class={[
        "card glass-card shadow-sm max-w-full cursor-pointer hover:shadow-md transition-shadow",
        if(@is_reply,
          do: "border-l-4 border-l-error bg-error/5 border-t border-r border-b border-base-300",
          else: "border border-base-300"
        )
      ]}
      data-post-id={@post.id}
      data-source={@source}
      phx-hook="PostClick"
      data-click-event={@click_event}
      data-id={@post.id}
      data-url={
        if @post.federated && @post.activitypub_id,
          do: URI.encode_www_form(@post.activitypub_id),
          else: nil
      }
    >
      <div class="card-body p-4 min-w-0">
        <!-- Boosted By Indicator -->
        <.boost_indicator post={@post} />
        
    <!-- Post Header -->
        <.post_header
          post={@post}
          current_user={@current_user}
          timezone={@timezone}
          time_format={@time_format}
          user_statuses={@user_statuses}
          id_prefix={@id_prefix}
          on_navigate_profile={@on_navigate_profile}
          show_admin_actions={@show_admin_actions}
        />
        
    <!-- Content Journey Trail -->
        <.content_journey message={@post} context={@source} />
        
    <!-- Reply Indicator -->
        <.reply_indicator post={@post} resolve_reply_refs={@resolve_reply_refs} />
        
    <!-- Post Content -->
        <.post_content
          post={@post}
          current_user={@current_user}
          is_gallery_post={@is_gallery_post}
          on_image_click={@on_image_click}
        />
        
    <!-- Post Actions -->
        <.post_footer
          post={@post}
          current_user={@current_user}
          user_likes={@user_likes}
          user_boosts={@user_boosts}
          user_saves={@user_saves}
          user_follows={@user_follows}
          pending_follows={@pending_follows}
          display_like_count={@display_like_count}
          display_comment_count={@display_comment_count}
          show_follow_button={@show_follow_button}
          show_view_button={@show_view_button}
        />
        
    <!-- Emoji Reactions -->
        <div class="mt-2 pt-2 border-t border-base-200" phx-click="stop_propagation">
          <.post_reactions
            post_id={@post.id}
            reactions={@reactions}
            current_user={@current_user}
            size={:xs}
          />
        </div>
      </div>
    </div>
    """
  end

  # Boost indicator component
  attr :post, :map, required: true

  defp boost_indicator(assigns) do
    ~H"""
    <%= if is_map(@post.media_metadata) && is_map(@post.media_metadata["boosted_by"]) do %>
      <% booster = @post.media_metadata["boosted_by"]

      has_booster_data =
        is_binary(booster["domain"]) && booster["domain"] != "" &&
          is_binary(booster["username"]) && booster["username"] != ""

      # Filter out relay actors - they distribute content, not boost it
      is_relay =
        has_booster_data &&
          (String.contains?(String.downcase(booster["username"] || ""), "relay") ||
             String.starts_with?(String.downcase(booster["domain"] || ""), "relay.")) %>
      <%= if has_booster_data && !is_relay do %>
        <div class="flex items-center gap-2 mb-3 text-sm opacity-70 min-w-0">
          <.icon name="hero-arrow-path" class="w-4 h-4 text-success flex-shrink-0" />
          <span class="flex-shrink-0">Boosted by</span>
          <.link
            navigate={"/remote/#{booster["username"]}@#{booster["domain"]}"}
            class="flex-shrink-0"
            phx-click="stop_propagation"
          >
            <%= if booster["avatar_url"] do %>
              <img
                src={ensure_https(booster["avatar_url"])}
                alt=""
                class="w-5 h-5 rounded-full object-cover"
              />
            <% else %>
              <.placeholder_avatar size="xs" class="w-5 h-5" />
            <% end %>
          </.link>
          <.link
            navigate={"/remote/#{booster["username"]}@#{booster["domain"]}"}
            class="font-medium text-success truncate min-w-0"
            phx-click="stop_propagation"
          >
            {raw(
              render_display_name_with_emojis(
                booster["display_name"] || booster["username"],
                booster["domain"]
              )
            )}
          </.link>
          <span class="text-xs opacity-60 truncate flex-shrink min-w-0">
            @{booster["username"]}@{booster["domain"]}
          </span>
        </div>
      <% end %>
    <% end %>
    """
  end

  # Post header component
  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "12h"
  attr :user_statuses, :map, default: %{}
  attr :id_prefix, :string, default: "post"
  attr :on_navigate_profile, :string, default: "navigate_to_profile"
  attr :show_admin_actions, :boolean, default: true

  defp post_header(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-3">
      <%= if @post.federated && Ecto.assoc_loaded?(@post.remote_actor) && @post.remote_actor do %>
        <!-- Remote federated post -->
        <.remote_author_header
          post={@post}
          timezone={@timezone}
          time_format={@time_format}
        />
      <% else %>
        <!-- Local post -->
        <%= if @post.sender do %>
          <.local_author_header
            post={@post}
            timezone={@timezone}
            time_format={@time_format}
            user_statuses={@user_statuses}
            on_navigate_profile={@on_navigate_profile}
          />
        <% end %>
      <% end %>
      
    <!-- Post Actions Dropdown -->
      <%= if @current_user do %>
        <.post_dropdown
          post={@post}
          current_user={@current_user}
          show_admin_actions={@show_admin_actions}
        />
      <% end %>
    </div>
    """
  end

  # Remote author header
  attr :post, :map, required: true
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "12h"

  defp remote_author_header(assigns) do
    community_uri = PostUtilities.community_actor_uri(assigns.post)
    assigns = assign(assigns, :community_uri, community_uri)

    ~H"""
    <.user_hover_card remote_actor={@post.remote_actor}>
      <.link
        navigate={"/remote/#{@post.remote_actor.username}@#{@post.remote_actor.domain}"}
        class="w-10 h-10 rounded-full block"
        phx-click="stop_propagation"
      >
        <%= if @post.remote_actor.avatar_url do %>
          <img
            src={@post.remote_actor.avatar_url}
            alt={@post.remote_actor.username}
            class="w-10 h-10 rounded-full object-cover shadow-lg"
          />
        <% else %>
          <.placeholder_avatar size="md" class="shadow-lg" />
        <% end %>
      </.link>
    </.user_hover_card>
    <div class="flex-1 min-w-0 flex flex-col justify-center">
      <div class="flex items-center gap-1.5">
        <.user_hover_card remote_actor={@post.remote_actor}>
          <.link
            navigate={"/remote/#{@post.remote_actor.username}@#{@post.remote_actor.domain}"}
            class="font-medium hover:text-purple-600 transition-colors duration-200 truncate"
            phx-click="stop_propagation"
          >
            {raw(
              render_display_name_with_emojis(
                @post.remote_actor.display_name || @post.remote_actor.username,
                @post.remote_actor.domain
              )
            )}
          </.link>
        </.user_hover_card>
      </div>
      <div class="text-sm opacity-70 flex items-center gap-2 truncate">
        <span class="truncate">
          @{@post.remote_actor.username}@{@post.remote_actor.domain}
          <%= if @community_uri do %>
            <span class="opacity-50">in</span>
            <a href={@community_uri} target="_blank" rel="noopener noreferrer" class="link link-hover">
              {extract_community_name(@community_uri)}
            </a>
          <% end %>
          ·
          <.local_time
            datetime={@post.inserted_at}
            format="relative"
            timezone={@timezone}
            time_format={@time_format}
          />
        </span>
        <span class="badge badge-xs badge-outline flex-shrink-0" title="Federated post">
          <.icon name="hero-globe-alt" class="w-2.5 h-2.5" />
        </span>
        <%= if @post.edited_at do %>
          <span
            class="badge badge-xs badge-ghost"
            title={"Edited #{Elektrine.Social.time_ago_in_words(@post.edited_at)}"}
          >
            <.icon name="hero-pencil" class="w-2.5 h-2.5" />
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  # Local author header
  attr :post, :map, required: true
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "12h"
  attr :user_statuses, :map, default: %{}
  attr :on_navigate_profile, :string, default: "navigate_to_profile"

  defp local_author_header(assigns) do
    ~H"""
    <.user_hover_card user={@post.sender} user_statuses={@user_statuses}>
      <button
        phx-click={@on_navigate_profile}
        phx-value-handle={@post.sender.handle || @post.sender.username}
        class="w-10 h-10"
        type="button"
      >
        <.user_avatar user={@post.sender} size="sm" user_statuses={@user_statuses} />
      </button>
    </.user_hover_card>
    <div class="flex-1 min-w-0 flex flex-col justify-center">
      <.user_hover_card user={@post.sender} user_statuses={@user_statuses}>
        <button
          phx-click={@on_navigate_profile}
          phx-value-handle={@post.sender.handle || @post.sender.username}
          class="font-medium hover:text-error transition-colors text-left truncate"
          type="button"
        >
          <.username_with_effects user={@post.sender} display_name={true} verified_size="sm" />
        </button>
      </.user_hover_card>
      <div class="text-sm opacity-70 flex items-center gap-2 truncate">
        <span class="truncate">
          @{@post.sender.handle || @post.sender.username}@z.org ·
          <.local_time
            datetime={@post.inserted_at}
            format="relative"
            timezone={@timezone}
            time_format={@time_format}
          />
        </span>
        <%= if @post.edited_at do %>
          <span
            class="badge badge-xs badge-ghost flex-shrink-0"
            title={"Edited #{Elektrine.Social.time_ago_in_words(@post.edited_at)}"}
          >
            <.icon name="hero-pencil" class="w-2.5 h-2.5" />
          </span>
        <% end %>
        <.visibility_badge visibility={@post.visibility} />
      </div>
    </div>
    """
  end

  # Visibility badge component
  attr :visibility, :string, default: "public"

  defp visibility_badge(assigns) do
    ~H"""
    <%= case @visibility do %>
      <% "public" -> %>
        <span class="badge badge-xs badge-ghost" title="Public - Everyone can see">
          <.icon name="hero-globe-alt" class="w-3 h-3" />
        </span>
      <% "followers" -> %>
        <span class="badge badge-xs badge-info" title="Followers Only">
          <.icon name="hero-user-group" class="w-3 h-3" />
        </span>
      <% "friends" -> %>
        <span class="badge badge-xs badge-success" title="Friends Only">
          <.icon name="hero-heart" class="w-3 h-3" />
        </span>
      <% "private" -> %>
        <span class="badge badge-xs badge-warning" title="Private - Only you can see">
          <.icon name="hero-lock-closed" class="w-3 h-3" />
        </span>
      <% _ -> %>
    <% end %>
    """
  end

  # Post dropdown menu
  attr :post, :map, required: true
  attr :current_user, :map, required: true
  attr :show_admin_actions, :boolean, default: true

  defp post_dropdown(assigns) do
    ~H"""
    <div
      class="dropdown dropdown-end ml-auto flex-shrink-0"
      id={"post-dropdown-#{@post.id}"}
    >
      <label tabindex="0" class="btn btn-ghost btn-xs btn-square h-7 w-7 min-h-0 sm:h-8 sm:w-8">
        <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
      </label>
      <ul
        tabindex="0"
        class="dropdown-content z-30 menu p-2 shadow-lg bg-base-100 rounded-box w-52 z-30"
      >
        <!-- View/Open Actions -->
        <%= if @post.federated && @post.activitypub_url do %>
          <li>
            <a href={@post.activitypub_url} target="_blank" rel="noopener noreferrer">
              <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" /> Open on Remote Instance
            </a>
          </li>
        <% else %>
          <li>
            <button phx-click="view_post" phx-value-message_id={@post.id} type="button">
              <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" /> View Post
            </button>
          </li>
        <% end %>
        <li>
          <button phx-click="copy_post_link" phx-value-message_id={@post.id} type="button">
            <.icon name="hero-link" class="w-4 h-4" /> Copy Link
          </button>
        </li>
        
    <!-- Owner Actions -->
        <%= if @current_user && !@post.federated && @post.sender && @post.sender.id == @current_user.id do %>
          <div class="divider my-1"></div>
          <li>
            <button
              phx-click="delete_post"
              phx-value-message_id={@post.id}
              class="text-error"
              data-confirm="Are you sure you want to delete this post?"
              type="button"
            >
              <.icon name="hero-trash" class="w-4 h-4" /> Delete Post
            </button>
          </li>
        <% else %>
          <div class="divider my-1"></div>
          <li>
            <button phx-click="report_post" phx-value-message_id={@post.id} type="button">
              <.icon name="hero-flag" class="w-4 h-4" /> Report Post
            </button>
          </li>
          <li>
            <button phx-click="not_interested" phx-value-post_id={@post.id} type="button">
              <.icon name="hero-hand-thumb-down" class="w-4 h-4" /> Not Interested
            </button>
          </li>
          <li>
            <button phx-click="hide_post" phx-value-post_id={@post.id} type="button">
              <.icon name="hero-eye-slash" class="w-4 h-4" /> Hide Post
            </button>
          </li>
        <% end %>
        
    <!-- Admin Actions -->
        <%= if @show_admin_actions && @current_user.is_admin do %>
          <div class="divider my-1"></div>
          <li class="menu-title text-xs">
            <span class="text-warning">Admin Actions</span>
          </li>
          <li>
            <button
              phx-click="delete_post_admin"
              phx-value-message_id={@post.id}
              class="text-error"
              data-confirm="Are you sure you want to delete this post?"
              type="button"
            >
              <.icon name="hero-shield-exclamation" class="w-4 h-4" /> Admin Delete
            </button>
          </li>
        <% end %>
      </ul>
    </div>
    """
  end

  # Reply indicator component - shows what post is being replied to
  attr :post, :map, required: true
  attr :resolve_reply_refs, :boolean, default: false

  defp reply_indicator(assigns) do
    post = assigns.post

    # Check if we have full reply_to data loaded
    has_loaded_reply =
      post.reply_to_id && Ecto.assoc_loaded?(post.reply_to) && post.reply_to

    # Check if we have inReplyTo metadata (federated posts)
    in_reply_to_url = get_in(post.media_metadata || %{}, ["inReplyTo"])
    in_reply_to_author = get_in(post.media_metadata || %{}, ["inReplyToAuthor"])

    # For older cached replies, reply_to_id may be missing even when we have the
    # parent post locally. Resolve by ActivityPub reference before falling back
    # to external-only display.
    resolved_reply =
      cond do
        has_loaded_reply ->
          post.reply_to

        is_binary(in_reply_to_url) && assigns.resolve_reply_refs ->
          Messaging.get_message_by_activitypub_ref(in_reply_to_url)

        true ->
          nil
      end

    has_resolved_reply = !is_nil(resolved_reply)

    # Determine if this is a reply at all
    is_reply = has_resolved_reply || in_reply_to_url

    # Determine click behavior
    {click_event, click_url, click_id} =
      cond do
        has_resolved_reply ->
          {"navigate_to_embedded_post", nil, resolved_reply.id}

        in_reply_to_url ->
          {"open_external_link", in_reply_to_url, nil}

        true ->
          {nil, nil, nil}
      end

    # Get author info
    author_info =
      cond do
        has_resolved_reply && resolved_reply.federated &&
          Ecto.assoc_loaded?(resolved_reply.remote_actor) && resolved_reply.remote_actor ->
          %{
            name:
              "@#{resolved_reply.remote_actor.username}@#{resolved_reply.remote_actor.domain}",
            type: :federated
          }

        has_resolved_reply && Ecto.assoc_loaded?(resolved_reply.sender) && resolved_reply.sender ->
          %{
            name: "@#{resolved_reply.sender.handle || resolved_reply.sender.username}@z.org",
            type: :local
          }

        in_reply_to_author ->
          %{name: in_reply_to_author, type: :federated}

        in_reply_to_url ->
          # Extract domain from URL as fallback
          host = URI.parse(in_reply_to_url).host
          %{name: "a post on #{host}", type: :external}

        true ->
          %{name: "a post", type: :unknown}
      end

    # Get content preview - check loaded reply first, then metadata
    in_reply_to_content = get_in(post.media_metadata || %{}, ["inReplyToContent"])

    content =
      cond do
        has_resolved_reply && resolved_reply.content ->
          resolved_reply.content

        in_reply_to_content ->
          in_reply_to_content

        true ->
          nil
      end

    reply_instance_domain =
      cond do
        has_resolved_reply ->
          PostUtilities.get_instance_domain(resolved_reply)

        in_reply_to_url ->
          URI.parse(in_reply_to_url).host

        true ->
          nil
      end

    assigns =
      assigns
      |> assign(:is_reply, is_reply)
      |> assign(:has_resolved_reply, has_resolved_reply)
      |> assign(:in_reply_to_url, in_reply_to_url)
      |> assign(:click_event, click_event)
      |> assign(:click_url, click_url)
      |> assign(:click_id, click_id)
      |> assign(:author_info, author_info)
      |> assign(:reply_content, content)
      |> assign(:reply_instance_domain, reply_instance_domain)

    ~H"""
    <%= if @is_reply do %>
      <div phx-click="stop_propagation" class="mb-3">
        <%= if @click_event do %>
          <button
            type="button"
            phx-click={@click_event}
            phx-value-url={@click_url}
            phx-value-id={@click_id}
            class={[
              "block w-full text-left border-l-4 pl-3 py-2 rounded-r-lg transition-all cursor-pointer",
              case @author_info.type do
                :federated ->
                  "border-purple-400 bg-purple-50 dark:bg-purple-900/10 hover:bg-purple-100 dark:hover:bg-purple-900/20 hover:border-purple-500"

                :local ->
                  "border-error/40 bg-error/5 hover:bg-error/10 hover:border-error"

                :external ->
                  "border-secondary/40 bg-secondary/5 hover:bg-secondary/10 hover:border-secondary"

                _ ->
                  "border-base-300 bg-base-200/50 hover:bg-base-200"
              end
            ]}
          >
            <div class="flex items-center gap-2 text-sm">
              <.icon name="hero-arrow-uturn-left" class="w-4 h-4 opacity-60" />
              <span class="opacity-70">Replying to</span>
              <span class={[
                "font-medium",
                case @author_info.type do
                  :federated -> "text-purple-600"
                  :local -> "text-error"
                  :external -> "text-secondary"
                  _ -> ""
                end
              ]}>
                {@author_info.name}
              </span>
              <%= if @in_reply_to_url && !@has_resolved_reply do %>
                <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 ml-auto opacity-50" />
              <% end %>
            </div>
            <%= if @reply_content do %>
              <div class="mt-2 text-sm opacity-70 line-clamp-3 break-words pl-6">
                {raw(PostUtilities.render_content_preview(@reply_content, @reply_instance_domain))}
              </div>
            <% else %>
              <%= if @in_reply_to_url && !@has_resolved_reply do %>
                <div class="mt-1 text-xs opacity-50 pl-6">
                  Click to view the original post
                </div>
              <% end %>
            <% end %>
          </button>
        <% else %>
          <div class="border-l-4 border-base-300 bg-base-200/50 pl-3 py-2 rounded-r-lg">
            <div class="flex items-center gap-2 text-sm">
              <.icon name="hero-arrow-uturn-left" class="w-4 h-4 opacity-60" />
              <span class="opacity-70">This is a reply</span>
            </div>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  # Post content component
  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :is_gallery_post, :boolean, default: false
  attr :on_image_click, :string, default: "open_image_modal"

  defp post_content(assigns) do
    ~H"""
    <!-- Title -->
    <%= if @post.title do %>
      <h3 class="font-semibold text-lg mb-2 break-words leading-tight post-content">
        {@post.title}
        <%= if @post.auto_title do %>
          <span class="text-xs opacity-50 ml-2">(auto)</span>
        <% end %>
      </h3>
    <% end %>

    <!-- Content Warning Indicator -->
    <%= if @post.content_warning && String.trim(@post.content_warning) != "" do %>
      <div class="mb-3 flex items-center gap-2 bg-warning/10 border border-warning/30 rounded-lg p-3">
        <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning flex-shrink-0" />
        <span class="font-medium text-sm">{@post.content_warning}</span>
        <span class="badge badge-sm badge-warning ml-auto">Sensitive</span>
      </div>
    <% end %>

    <!-- Main Content -->
    <div class={"mb-3 min-w-0 #{if @post.content_warning && String.trim(@post.content_warning) != "", do: "blur-sm hover:blur-none transition-all", else: ""}"}>
      <!-- Quoted post content -->
      <%= if @post.quoted_message_id && Ecto.assoc_loaded?(@post.quoted_message) && @post.quoted_message do %>
        <%= if @post.content && @post.content != "" do %>
          <div class="break-words mb-3 post-content line-clamp-4 overflow-hidden">
            {raw(render_post_content(@post))}
          </div>
        <% end %>
        <div
          phx-click="stop_propagation"
          class="border border-base-300 rounded-lg p-3 bg-base-200/30 hover:bg-base-200/50 transition-colors"
        >
          <div class="flex items-center gap-2 mb-2">
            <.icon name="hero-chat-bubble-bottom-center-text" class="w-4 h-4 text-info flex-shrink-0" />
            <span class="text-xs font-medium text-info">Quoting</span>
          </div>
          <div class="flex items-center gap-2 mb-2">
            <%= if @post.quoted_message.sender do %>
              <.user_hover_card user={@post.quoted_message.sender}>
                <button
                  phx-click="navigate_to_profile"
                  phx-value-handle={
                    @post.quoted_message.sender.handle || @post.quoted_message.sender.username
                  }
                  class="w-6 h-6"
                  type="button"
                >
                  <.user_avatar user={@post.quoted_message.sender} size="xs" />
                </button>
              </.user_hover_card>
              <.user_hover_card user={@post.quoted_message.sender}>
                <button
                  phx-click="navigate_to_profile"
                  phx-value-handle={
                    @post.quoted_message.sender.handle || @post.quoted_message.sender.username
                  }
                  class="font-medium text-sm hover:text-error transition-colors"
                  type="button"
                >
                  <.username_with_effects
                    user={@post.quoted_message.sender}
                    display_name={true}
                    verified_size="xs"
                  />
                </button>
              </.user_hover_card>
              <span class="text-xs opacity-60">@{@post.quoted_message.sender.username}</span>
            <% else %>
              <%= if Ecto.assoc_loaded?(@post.quoted_message.remote_actor) && @post.quoted_message.remote_actor do %>
                <.link
                  navigate={"/remote/#{@post.quoted_message.remote_actor.username}@#{@post.quoted_message.remote_actor.domain}"}
                  class="w-6 h-6"
                >
                  <%= if @post.quoted_message.remote_actor.avatar_url do %>
                    <img
                      src={@post.quoted_message.remote_actor.avatar_url}
                      alt=""
                      class="w-6 h-6 rounded-full object-cover"
                    />
                  <% else %>
                    <.placeholder_avatar size="xs" class="w-6 h-6" />
                  <% end %>
                </.link>
                <.link
                  navigate={"/remote/#{@post.quoted_message.remote_actor.username}@#{@post.quoted_message.remote_actor.domain}"}
                  class="font-medium text-sm hover:text-purple-600 transition-colors"
                >
                  {raw(
                    render_display_name_with_emojis(
                      @post.quoted_message.remote_actor.display_name ||
                        @post.quoted_message.remote_actor.username,
                      @post.quoted_message.remote_actor.domain
                    )
                  )}
                </.link>
                <span class="text-xs opacity-60">
                  @{@post.quoted_message.remote_actor.username}@{@post.quoted_message.remote_actor.domain}
                </span>
              <% end %>
            <% end %>
          </div>
          <%= if @post.quoted_message.content do %>
            <div class="text-sm line-clamp-4 opacity-80 break-words">
              {raw(render_post_content(@post.quoted_message))}
            </div>
          <% end %>
          <%= if @post.quoted_message.media_urls && length(@post.quoted_message.media_urls) > 0 do %>
            <div class="mt-2 flex gap-1">
              <%= for media_url <- Enum.take(@post.quoted_message.media_urls, 2) do %>
                <% full_url = Elektrine.Uploads.attachment_url(media_url) %>
                <img src={full_url} alt="" class="w-16 h-16 rounded object-cover" />
              <% end %>
              <%= if length(@post.quoted_message.media_urls) > 2 do %>
                <div class="w-16 h-16 rounded bg-base-300 flex items-center justify-center text-xs opacity-60">
                  +{length(@post.quoted_message.media_urls) - 2}
                </div>
              <% end %>
            </div>
          <% end %>
          <%= if Ecto.assoc_loaded?(@post.quoted_message.link_preview) && match?(%LinkPreview{}, @post.quoted_message.link_preview) && @post.quoted_message.link_preview.status == "success" do %>
            <div class="mt-2 border border-base-300 rounded overflow-hidden">
              <a
                href={@post.quoted_message.link_preview.url}
                target="_blank"
                rel="noopener noreferrer"
                class="flex items-center gap-2 p-2 hover:bg-base-200/50 transition-colors"
              >
                <%= if @post.quoted_message.link_preview.image_url do %>
                  <img
                    src={ensure_https(@post.quoted_message.link_preview.image_url)}
                    alt=""
                    class="w-12 h-12 rounded object-cover flex-shrink-0"
                    onerror="this.style.display='none'"
                  />
                <% end %>
                <div class="min-w-0 flex-1">
                  <%= if @post.quoted_message.link_preview.title do %>
                    <div class="text-xs font-medium truncate">
                      {String.slice(@post.quoted_message.link_preview.title, 0, 60)}
                    </div>
                  <% end %>
                  <div class="text-xs opacity-60 truncate">
                    {URI.parse(@post.quoted_message.link_preview.url).host}
                  </div>
                </div>
              </a>
            </div>
          <% end %>
        </div>
      <% else %>
        <!-- Cross-posted content -->
        <%= if @post.shared_message_id && @post.shared_message do %>
          <%= if @post.content && @post.content != "" do %>
            <div class="break-words mb-3 post-content line-clamp-4 overflow-hidden">
              {raw(render_post_content(@post))}
            </div>
          <% end %>
          <div phx-click="stop_propagation">
            <.embedded_post
              message={@post}
              shared_message={@post.shared_message}
              class="mt-3"
            />
          </div>
        <% else %>
          <!-- Poll Display -->
          <%= if @post.post_type == "poll" && Ecto.assoc_loaded?(@post.poll) && @post.poll do %>
            <% user_votes =
              if @current_user,
                do: Elektrine.Social.get_user_poll_votes(@post.poll.id, @current_user.id),
                else: [] %>
            <div class="mt-3" phx-click="stop_propagation">
              <ElektrineWeb.Components.Social.PollDisplay.poll_card
                poll={@post.poll}
                message={@post}
                current_user={@current_user}
                user_votes={user_votes}
              />
            </div>
          <% else %>
            <!-- Regular post content -->
            <%= if @post.content && @post.content != "" do %>
              <div class="break-words post-content line-clamp-6 overflow-hidden">
                {raw(render_post_content(@post))}
              </div>
            <% end %>
          <% end %>
        <% end %>
      <% end %>
      
    <!-- Link to original post for federated posts -->
      <%= if @post.federated && @post.activitypub_url && @post.post_type != "poll" do %>
        <a
          href={@post.activitypub_url}
          target="_blank"
          rel="noopener noreferrer"
          class="text-xs text-purple-600 hover:underline flex items-center gap-1 mt-2"
          phx-click="stop_propagation"
        >
          <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
          <%= if PostUtilities.reply?(@post) do %>
            View full thread on {if @post.remote_actor,
              do: @post.remote_actor.domain,
              else: "original instance"}
          <% else %>
            View on {if @post.remote_actor, do: @post.remote_actor.domain, else: "original instance"}
          <% end %>
        </a>
      <% end %>
      
    <!-- YouTube Embed -->
      <.youtube_embed post={@post} />
      
    <!-- Direct Image URLs from content -->
      <.content_images
        post={@post}
        is_gallery_post={@is_gallery_post}
        on_image_click={@on_image_click}
      />
      
    <!-- Media attachments -->
      <.media_attachments
        post={@post}
        is_gallery_post={@is_gallery_post}
        on_image_click={@on_image_click}
      />
      
    <!-- Link Preview -->
      <.link_preview post={@post} />
    </div>
    """
  end

  # YouTube embed component
  attr :post, :map, required: true

  defp youtube_embed(assigns) do
    has_link_preview =
      match?(%LinkPreview{}, assigns.post.link_preview) &&
        assigns.post.link_preview.status == "success"

    youtube_url =
      if !has_link_preview && assigns.post.content,
        do: Elektrine.Messaging.Message.extract_youtube_embed_url(assigns.post.content),
        else: nil

    assigns = assign(assigns, :youtube_url, youtube_url)

    ~H"""
    <%= if @youtube_url do %>
      <div class="mt-3 aspect-video w-full" phx-click="stop_propagation">
        <iframe
          src={@youtube_url}
          width="100%"
          height="100%"
          frameborder="0"
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
          allowfullscreen
          class="rounded-lg"
        >
        </iframe>
      </div>
    <% end %>
    """
  end

  # Content images component (images extracted from content text)
  attr :post, :map, required: true
  attr :is_gallery_post, :boolean, default: false
  attr :on_image_click, :string, default: "open_image_modal"

  defp content_images(assigns) do
    image_urls = Elektrine.Messaging.Message.extract_image_urls(assigns.post.content)
    assigns = assign(assigns, :image_urls, image_urls)

    ~H"""
    <%= if @image_urls != [] do %>
      <div class="mt-3 space-y-2" phx-click="stop_propagation">
        <%= for {image_url, idx} <- Enum.with_index(@image_urls) do %>
          <button
            type="button"
            phx-click={@on_image_click}
            phx-value-id={@post.id}
            phx-value-url={image_url}
            phx-value-images={Jason.encode!(@image_urls)}
            phx-value-index={idx}
            phx-value-post_id={@post.id}
            class="block w-full"
          >
            <img
              src={image_url}
              alt="Image preview"
              class="max-w-full rounded-lg max-h-96 object-contain hover:opacity-90 transition-opacity cursor-pointer"
              loading="lazy"
              onerror="this.style.display='none'"
            />
          </button>
        <% end %>
      </div>
    <% end %>
    """
  end

  # Media attachments component
  attr :post, :map, required: true
  attr :is_gallery_post, :boolean, default: false
  attr :on_image_click, :string, default: "open_image_modal"

  defp media_attachments(assigns) do
    media_urls = assigns.post.media_urls || []
    full_media_urls = Enum.map(media_urls, &Elektrine.Uploads.attachment_url/1)

    alt_texts =
      if assigns.post.media_metadata && assigns.post.media_metadata["alt_texts"],
        do: assigns.post.media_metadata["alt_texts"],
        else: %{}

    assigns =
      assigns
      |> assign(:media_urls, media_urls)
      |> assign(:full_media_urls, full_media_urls)
      |> assign(:alt_texts, alt_texts)

    ~H"""
    <%= if @media_urls != [] do %>
      <div class="mt-3 grid grid-cols-1 gap-2" phx-click="stop_propagation">
        <%= for {media_url, idx} <- Enum.with_index(@media_urls) do %>
          <% full_url = Elektrine.Uploads.attachment_url(media_url)
          alt_text = Map.get(@alt_texts, to_string(idx), "Posted media")
          is_video = video_url?(full_url)
          is_audio = audio_url?(full_url) %>
          <%= cond do %>
            <% is_video -> %>
              <video src={full_url} controls preload="metadata" class="rounded-lg max-h-96 w-full">
                Your browser does not support the video tag.
              </video>
            <% is_audio -> %>
              <audio src={full_url} controls preload="metadata" class="w-full">
                Your browser does not support the audio tag.
              </audio>
            <% true -> %>
              <button
                type="button"
                phx-click={@on_image_click}
                phx-value-id={@post.id}
                phx-value-url={full_url}
                phx-value-images={Jason.encode!(@full_media_urls)}
                phx-value-index={idx}
                phx-value-post_id={@post.id}
                class="block w-full"
              >
                <img
                  src={full_url}
                  alt={alt_text}
                  class="rounded-lg max-h-96 object-cover w-full cursor-pointer hover:opacity-90 transition-opacity"
                  loading="lazy"
                />
              </button>
          <% end %>
        <% end %>
      </div>
    <% end %>
    """
  end

  # Link preview component
  attr :post, :map, required: true

  defp link_preview(assigns) do
    ~H"""
    <%= if match?(%LinkPreview{}, @post.link_preview) && @post.link_preview.status == "success" do %>
      <div
        class="mt-3 border border-base-300 rounded-lg overflow-hidden hover:border-base-300 transition-colors max-w-full"
        phx-click="stop_propagation"
      >
        <a
          href={@post.link_preview.url}
          target="_blank"
          rel="noopener noreferrer"
          class="block min-w-0"
        >
          <%= if @post.link_preview.image_url do %>
            <div class="aspect-video bg-base-50">
              <img
                src={ensure_https(@post.link_preview.image_url)}
                alt={@post.link_preview.title || ""}
                class="w-full h-full object-cover"
                onerror="this.parentElement.style.display='none'"
              />
            </div>
          <% end %>
          <div class="p-3 min-w-0">
            <div class="flex items-center gap-2 mb-2">
              <%= if @post.link_preview.favicon_url do %>
                <img
                  src={ensure_https(@post.link_preview.favicon_url)}
                  alt=""
                  class="w-4 h-4 flex-shrink-0"
                  onerror="this.style.display='none'"
                />
              <% end %>
              <span class="text-xs text-base-content/60 truncate">
                {@post.link_preview.site_name || URI.parse(@post.link_preview.url).host}
              </span>
            </div>
            <%= if @post.link_preview.title do %>
              <h4 class="font-medium text-sm mb-1 break-words">
                {String.slice(@post.link_preview.title, 0, 100)}
              </h4>
            <% end %>
            <%= if @post.link_preview.description do %>
              <p class="text-xs text-base-content/70 break-words">
                {String.slice(@post.link_preview.description, 0, 200)}
              </p>
            <% end %>
          </div>
        </a>
      </div>
    <% end %>
    """
  end

  # Post footer with actions
  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :user_likes, :map, default: %{}
  attr :user_boosts, :map, default: %{}
  attr :user_saves, :map, default: %{}
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :display_like_count, :integer, default: 0
  attr :display_comment_count, :integer, default: 0
  attr :show_follow_button, :boolean, default: true
  attr :show_view_button, :boolean, default: false

  defp post_footer(assigns) do
    ~H"""
    <div
      class="flex flex-wrap items-center justify-between gap-y-2 gap-x-1 pt-2 border-t border-base-300"
      phx-click="stop_propagation"
    >
      <div class="flex items-center gap-1 flex-shrink-0">
        <.post_actions
          post_id={@post.id}
          current_user={@current_user}
          is_liked={Map.get(@user_likes, @post.id, false)}
          is_boosted={Map.get(@user_boosts, @post.id, false)}
          is_saved={Map.get(@user_saves, @post.id, false)}
          like_count={@display_like_count}
          comment_count={@display_comment_count}
          boost_count={@post.share_count || 0}
          quote_count={@post.quote_count || 0}
          value_name="message_id"
          size={:xs}
        />
        
    <!-- View Post Button (only shown on post detail page) -->
        <%= if @show_view_button do %>
          <%= if @post.federated && @post.activitypub_url do %>
            <a
              href={@post.activitypub_url}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-ghost btn-xs px-1.5 h-7 min-h-0 sm:px-2 sm:btn-sm"
              title="Open on remote instance"
            >
              <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 sm:w-4 sm:h-4" />
            </a>
          <% else %>
            <button
              phx-click="navigate_to_post"
              phx-value-id={@post.id}
              class="btn btn-ghost btn-xs px-1.5 h-7 min-h-0 sm:px-2 sm:btn-sm"
              type="button"
              title="View full post"
            >
              <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 sm:w-4 sm:h-4" />
            </button>
          <% end %>
        <% end %>
      </div>
      
    <!-- Follow Actions -->
      <%= if @show_follow_button && @current_user do %>
        <.follow_actions
          post={@post}
          current_user={@current_user}
          user_follows={@user_follows}
          pending_follows={@pending_follows}
        />
      <% end %>
    </div>
    """
  end

  # Follow actions component
  attr :post, :map, required: true
  attr :current_user, :map, required: true
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}

  defp follow_actions(assigns) do
    ~H"""
    <%= if @post.federated && @post.remote_actor do %>
      <% is_following = Map.get(@user_follows, {:remote, @post.remote_actor.id}, false)
      is_pending = Map.get(@pending_follows, {:remote, @post.remote_actor.id}, false) %>
      <div class="flex items-center gap-1">
        <button
          phx-click="toggle_follow_remote"
          phx-value-remote_actor_id={@post.remote_actor.id}
          class={[
            "btn btn-xs px-1.5 h-7 min-h-0 sm:px-2 sm:btn-sm",
            cond do
              is_following -> "btn-ghost"
              is_pending -> "btn-ghost"
              true -> "btn-secondary"
            end
          ]}
          type="button"
        >
          <%= cond do %>
            <% is_following -> %>
              <.icon name="hero-user-minus" class="w-3 h-3 sm:w-4 sm:h-4" />
              <span class="text-[10px] sm:text-sm ml-0.5 sm:ml-1 hidden min-[320px]:inline">
                Unfollow
              </span>
            <% is_pending -> %>
              <.icon name="hero-clock" class="w-3 h-3 sm:w-4 sm:h-4" />
              <span class="text-[10px] sm:text-sm ml-0.5 sm:ml-1 hidden min-[320px]:inline">
                Requested
              </span>
            <% true -> %>
              <.icon name="hero-user-plus" class="w-3 h-3 sm:w-4 sm:h-4" />
              <span class="text-[10px] sm:text-sm ml-0.5 sm:ml-1 hidden min-[320px]:inline">
                Follow
              </span>
          <% end %>
        </button>
      </div>
    <% end %>

    <%= if !@post.federated && @post.sender && @post.sender.id != @current_user.id do %>
      <% is_following = Map.get(@user_follows, {:local, @post.sender.id}, false) %>
      <div class="flex items-center gap-1">
        <button
          phx-click="toggle_follow"
          phx-value-user_id={@post.sender.id}
          class={[
            "btn btn-xs px-1.5 h-7 min-h-0 sm:px-2 sm:btn-sm",
            if(is_following, do: "btn-ghost", else: "btn-secondary")
          ]}
          type="button"
        >
          <%= if is_following do %>
            <.icon name="hero-user-minus" class="w-3 h-3 sm:w-4 sm:h-4" />
            <span class="text-[10px] sm:text-sm ml-0.5 sm:ml-1 hidden min-[320px]:inline">
              Unfollow
            </span>
          <% else %>
            <.icon name="hero-user-plus" class="w-3 h-3 sm:w-4 sm:h-4" />
            <span class="text-[10px] sm:text-sm ml-0.5 sm:ml-1 hidden min-[320px]:inline">
              Follow
            </span>
          <% end %>
        </button>
      </div>
    <% end %>
    """
  end

  # Lemmy/Reddit style layout with vote column
  defp render_lemmy_layout(assigns) do
    post = assigns.post
    post_id = post.activitypub_id || to_string(post.id)

    # Get interaction state
    post_state =
      Map.get(assigns.post_interactions, post_id, %{liked: false, downvoted: false, like_delta: 0})

    # Check user_likes/user_downvotes with fallback to post_interactions
    is_liked =
      case Map.fetch(assigns.user_likes, post.id) do
        {:ok, val} -> val
        :error -> Map.get(post_state, :liked, false)
      end

    is_downvoted =
      case Map.fetch(assigns.user_downvotes, post.id) do
        {:ok, val} -> val
        :error -> Map.get(post_state, :downvoted, false)
      end

    # Calculate like count
    like_delta = Map.get(post_state, :like_delta, 0)
    lemmy_counts = Map.get(assigns.lemmy_counts, post.activitypub_id)

    base_count =
      if lemmy_counts do
        lemmy_counts.score
      else
        post.like_count || 0
      end

    like_count = base_count + like_delta

    # Filter to actual image URLs
    image_urls = PostUtilities.filter_image_urls(post.media_urls || [])
    has_image = !Enum.empty?(image_urls)
    image_url = if has_image, do: thumbnail_url(hd(image_urls), 96), else: nil

    # Get title and community info
    title = get_in(post.media_metadata || %{}, ["name"])
    community_uri = PostUtilities.community_actor_uri(post)
    external_link = PostUtilities.detect_external_link(post)

    # Reply count
    local_reply_count = length(assigns.replies)

    remote_reply_count =
      cond do
        lemmy_counts ->
          lemmy_counts.comments || 0

        is_integer(get_in(post.media_metadata || %{}, ["remote_engagement", "replies"])) ->
          get_in(post.media_metadata || %{}, ["remote_engagement", "replies"])

        is_integer(post.reply_count) ->
          post.reply_count

        true ->
          0
      end

    reply_count = max(local_reply_count, remote_reply_count)

    # Format reactions
    current_user_id = if assigns.current_user, do: assigns.current_user.id, else: nil
    formatted_reactions = PostUtilities.format_reactions(assigns.reactions, current_user_id)

    assigns =
      assigns
      |> assign(:post_id, post_id)
      |> assign(:is_liked, is_liked)
      |> assign(:is_downvoted, is_downvoted)
      |> assign(:like_count, like_count)
      |> assign(:has_image, has_image)
      |> assign(:image_url, image_url)
      |> assign(:image_urls, image_urls)
      |> assign(:title, title)
      |> assign(:community_uri, community_uri)
      |> assign(:external_link, external_link)
      |> assign(:reply_count, reply_count)
      |> assign(:formatted_reactions, formatted_reactions)
      |> assign(:unique_id, "lemmy-post-#{post.id}")

    ~H"""
    <article
      id={@unique_id}
      class="card glass-card border border-base-300 rounded-lg overflow-hidden hover:shadow-md transition-all relative z-0"
      data-post-id={@post.id}
      data-source={@source}
      phx-hook="PostClick"
      data-click-event="navigate_to_remote_post"
      data-id={@post.id}
      data-url={if @post.activitypub_id, do: URI.encode_www_form(@post.activitypub_id), else: nil}
      role="article"
      aria-label={"Post: #{@title || "Untitled"}"}
    >
      <div class="flex">
        <!-- Vote Column -->
        <div
          class="flex flex-col items-center p-2 bg-base-200/50 gap-1 w-12 flex-shrink-0"
          role="group"
          aria-label="Voting"
        >
          <%= if @current_user do %>
            <button
              phx-click={if @is_liked, do: @on_unlike, else: @on_like}
              phx-value-post_id={@post.id}
              class={[
                "btn btn-ghost btn-sm btn-square min-h-[2.5rem] min-w-[2.5rem]",
                if(@is_liked, do: "text-secondary", else: "text-base-content/50 hover:text-secondary")
              ]}
              aria-label={if @is_liked, do: "Remove upvote", else: "Upvote"}
              aria-pressed={@is_liked}
            >
              <.icon
                name={if @is_liked, do: "hero-arrow-up-solid", else: "hero-arrow-up"}
                class="w-5 h-5"
              />
            </button>
          <% else %>
            <div class="text-base-content/30 p-2">
              <.icon name="hero-arrow-up" class="w-5 h-5" />
            </div>
          <% end %>
          <span
            class={[
              "text-sm font-bold",
              if(@is_liked, do: "text-secondary", else: if(@is_downvoted, do: "text-error", else: ""))
            ]}
            aria-label={"Score: #{@like_count}"}
          >
            {@like_count}
          </span>
          <%= if @current_user do %>
            <button
              phx-click={if @is_downvoted, do: @on_undownvote, else: @on_downvote}
              phx-value-post_id={@post.id}
              class={[
                "btn btn-ghost btn-sm btn-square min-h-[2.5rem] min-w-[2.5rem]",
                if(@is_downvoted, do: "text-error", else: "text-base-content/50 hover:text-error")
              ]}
              aria-label={if @is_downvoted, do: "Remove downvote", else: "Downvote"}
              aria-pressed={@is_downvoted}
            >
              <.icon
                name={if @is_downvoted, do: "hero-arrow-down-solid", else: "hero-arrow-down"}
                class="w-5 h-5"
              />
            </button>
          <% else %>
            <div class="text-base-content/30 p-2">
              <.icon name="hero-arrow-down" class="w-5 h-5" />
            </div>
          <% end %>
        </div>
        
    <!-- Thumbnail for image posts or link icon for link submissions -->
        <%= if @has_image do %>
          <div class="w-20 h-20 flex-shrink-0 m-2">
            <%= if @on_image_click do %>
              <img
                src={@image_url}
                alt=""
                class="w-full h-full object-cover rounded cursor-pointer hover:opacity-80 transition-opacity"
                loading="lazy"
                phx-click={@on_image_click}
                phx-value-images={Jason.encode!(@image_urls)}
                phx-value-index="0"
                phx-value-post_id={@post.id}
              />
            <% else %>
              <img src={@image_url} alt="" class="w-full h-full object-cover rounded" loading="lazy" />
            <% end %>
          </div>
        <% else %>
          <%= if @external_link do %>
            <a
              href={@external_link}
              target="_blank"
              rel="noopener noreferrer"
              class="w-20 h-20 flex-shrink-0 m-2 bg-base-200 rounded flex items-center justify-center hover:bg-base-300 transition-colors"
            >
              <.icon name="hero-link" class="w-8 h-8 text-primary" />
            </a>
          <% end %>
        <% end %>
        
    <!-- Post Content -->
        <div
          class="flex-1 p-2 min-w-0 cursor-pointer"
          phx-click="navigate_to_remote_post"
          phx-value-post_id={
            if @post.activitypub_id, do: URI.encode_www_form(@post.activitypub_id), else: @post.id
          }
        >
          <!-- Title -->
          <%= if @title do %>
            <%= if @external_link do %>
              <a href={@external_link} target="_blank" rel="noopener noreferrer" class="block">
                <h3 class="font-medium text-sm mb-1 line-clamp-2 hover:text-primary flex items-center gap-1">
                  {@title}
                  <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 flex-shrink-0" />
                </h3>
              </a>
            <% else %>
              <h3 class="font-medium text-sm mb-1 line-clamp-2 hover:text-secondary">{@title}</h3>
            <% end %>
          <% end %>
          
    <!-- Content preview (only if no title) -->
          <%= if @post.content && !@title do %>
            <div class="text-sm line-clamp-2 mb-1 break-words opacity-80">
              {raw(
                PostUtilities.render_content_preview(
                  @post.content,
                  PostUtilities.get_instance_domain(@post)
                )
              )}
            </div>
          <% end %>
          
    <!-- External link domain -->
          <%= if @external_link do %>
            <div class="text-xs text-primary truncate mb-1">
              <a
                href={@external_link}
                target="_blank"
                rel="noopener noreferrer"
                class="hover:underline flex items-center gap-1"
              >
                <.icon name="hero-link" class="w-3 h-3 flex-shrink-0" />
                <span class="truncate">{URI.parse(@external_link).host}</span>
              </a>
            </div>
          <% else %>
            <%= if @post.link_preview && !@has_image do %>
              <div class="text-xs text-primary truncate mb-1">
                <a
                  href={@post.link_preview.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="hover:underline flex items-center gap-1"
                  phx-click="stop_propagation"
                >
                  <.icon name="hero-link" class="w-3 h-3 flex-shrink-0" />
                  <span class="truncate">{URI.parse(@post.link_preview.url).host}</span>
                </a>
              </div>
            <% end %>
          <% end %>
          
    <!-- Meta line -->
          <div class="flex items-center gap-2 text-xs text-base-content/50 flex-wrap">
            <%= if Ecto.assoc_loaded?(@post.remote_actor) && @post.remote_actor do %>
              <.link
                navigate={"/remote/#{@post.remote_actor.username}@#{@post.remote_actor.domain}"}
                class="hover:underline"
                phx-click="stop_propagation"
              >
                @{@post.remote_actor.username}
              </.link>
              <span>·</span>
            <% end %>
            <%= if @community_uri do %>
              <span class="text-secondary">
                {PostUtilities.extract_community_name(@community_uri)}
              </span>
              <span>·</span>
            <% end %>
            <.local_time datetime={@post.inserted_at} format="relative" timezone={@timezone} />
            <span>·</span>
            <span>{@reply_count} comments</span>
            <%= if @post.activitypub_url do %>
              <a
                href={@post.activitypub_url}
                target="_blank"
                rel="noopener noreferrer"
                class="hover:text-primary ml-auto"
                phx-click="stop_propagation"
              >
                <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
              </a>
            <% end %>
          </div>
          
    <!-- Emoji Reactions -->
          <%= if @current_user || !Enum.empty?(@formatted_reactions) do %>
            <div class="flex items-center gap-1 mt-2 flex-wrap" phx-click="stop_propagation">
              <%= for {emoji, count, users, user_reacted} <- @formatted_reactions do %>
                <% tooltip =
                  if length(users) > 10 do
                    Enum.join(Enum.take(users, 10), ", ") <> " and #{length(users) - 10} more"
                  else
                    Enum.join(users, ", ")
                  end %>
                <%= if @current_user do %>
                  <button
                    phx-click={@on_react}
                    phx-value-post_id={@post.id}
                    phx-value-emoji={emoji}
                    class={[
                      "px-1.5 py-0.5 rounded text-xs border flex items-center gap-1 transition-colors tooltip tooltip-top",
                      if(user_reacted,
                        do: "bg-secondary/20 border-secondary text-secondary",
                        else: "bg-base-200 border-base-300 hover:bg-base-300"
                      )
                    ]}
                    data-tip={tooltip}
                  >
                    <span>{emoji}</span>
                    <span class="font-medium">{count}</span>
                  </button>
                <% else %>
                  <span
                    class="px-1.5 py-0.5 rounded text-xs bg-base-200 border border-base-300 flex items-center gap-1 tooltip tooltip-top"
                    data-tip={tooltip}
                  >
                    <span>{emoji}</span>
                    <span class="font-medium">{count}</span>
                  </span>
                <% end %>
              <% end %>
              
    <!-- Quick reaction buttons -->
              <%= if @current_user do %>
                <div class="flex items-center gap-0.5 ml-1">
                  <%= for emoji <- ~w(👍 ❤️ 😂 🔥 😮 😢) do %>
                    <% already_reacted =
                      Enum.any?(@formatted_reactions, fn {e, _, _, reacted} ->
                        e == emoji && reacted
                      end) %>
                    <button
                      phx-click={@on_react}
                      phx-value-post_id={@post.id}
                      phx-value-emoji={emoji}
                      class={[
                        "btn btn-ghost btn-xs px-1 text-sm",
                        if(already_reacted,
                          do: "text-secondary",
                          else: "opacity-40 hover:opacity-100"
                        )
                      ]}
                      title={emoji}
                    >
                      {emoji}
                    </button>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
      
    <!-- Threaded Comments Preview -->
      <%= if length(@replies) > 0 do %>
        <div class="border-t border-base-300 bg-base-50 px-3 py-2">
          <div class="text-xs font-medium text-base-content/60 mb-2">Top Community Comments</div>
          <div class="space-y-2">
            <%= for reply <- Enum.take(@replies, 3) do %>
              <div class="flex gap-2 text-sm">
                <div class="w-0.5 bg-base-300 flex-shrink-0"></div>
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-1 text-xs text-base-content/50 mb-0.5">
                    <span class="font-medium">
                      {PostUtilities.get_reply_author(reply)}
                    </span>
                    <% score = PostUtilities.get_reply_score(reply) %>
                    <%= if score && score > 0 do %>
                      <span class="text-secondary">+{score}</span>
                    <% end %>
                  </div>
                  <div class="line-clamp-2 text-xs break-words">
                    {raw(
                      PostUtilities.render_content_preview(
                        PostUtilities.get_reply_content(reply),
                        PostUtilities.get_instance_domain(reply)
                      )
                    )}
                  </div>
                </div>
              </div>
            <% end %>
            <%= if @reply_count > length(@replies) do %>
              <div
                class="text-xs text-primary cursor-pointer hover:underline"
                phx-click="navigate_to_remote_post"
                phx-value-post_id={
                  if @post.activitypub_id,
                    do: URI.encode_www_form(@post.activitypub_id),
                    else: @post.id
                }
              >
                View all {@reply_count} comments
              </div>
            <% end %>
            <%= if @post.federated && @post.activitypub_url do %>
              <a
                href={@post.activitypub_url}
                target="_blank"
                rel="noopener noreferrer"
                class="text-xs text-base-content/70 hover:text-primary inline-flex items-center gap-1"
                phx-click="stop_propagation"
              >
                <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                Open full origin thread
              </a>
            <% end %>
          </div>
        </div>
      <% end %>
    </article>
    """
  end

  # Compact layout for dense feeds
  defp render_compact_layout(assigns) do
    post = assigns.post
    is_reply = PostUtilities.reply?(post)
    is_gallery_post = PostUtilities.gallery_post?(post)
    click_event = assigns.click_event || PostUtilities.get_post_click_event(post)

    {display_like_count, display_comment_count} =
      PostUtilities.get_display_counts(post, assigns.lemmy_counts, assigns.post_replies)

    # Get title from metadata if available
    title = post.title || get_in(post.media_metadata || %{}, ["name"])

    # Get thumbnail if available
    image_urls = PostUtilities.filter_image_urls(post.media_urls || [])
    has_image = !Enum.empty?(image_urls)
    thumbnail = if has_image, do: thumbnail_url(hd(image_urls), 64), else: nil

    assigns =
      assigns
      |> assign(:is_reply, is_reply)
      |> assign(:is_gallery_post, is_gallery_post)
      |> assign(:click_event, click_event)
      |> assign(:display_like_count, display_like_count)
      |> assign(:display_comment_count, display_comment_count)
      |> assign(:title, title)
      |> assign(:has_image, has_image)
      |> assign(:thumbnail, thumbnail)

    ~H"""
    <div
      id={"compact-post-#{@post.id}"}
      class={[
        "flex items-start gap-3 p-3 border-b border-base-200 hover:bg-base-100 transition-colors cursor-pointer",
        if(@is_reply, do: "border-l-2 border-l-error/40", else: "")
      ]}
      data-post-id={@post.id}
      data-source={@source}
      phx-hook="PostClick"
      data-click-event={@click_event}
      data-id={@post.id}
      data-url={
        if @post.federated && @post.activitypub_id,
          do: URI.encode_www_form(@post.activitypub_id),
          else: nil
      }
    >
      <!-- Thumbnail -->
      <%= if @has_image do %>
        <div class="w-16 h-16 flex-shrink-0 rounded overflow-hidden">
          <img src={@thumbnail} alt="" class="w-full h-full object-cover" loading="lazy" />
        </div>
      <% end %>

      <div class="flex-1 min-w-0">
        <!-- Title or content preview -->
        <%= if @title do %>
          <h3 class="font-medium text-sm line-clamp-2 mb-1">{@title}</h3>
        <% else %>
          <%= if @post.content do %>
            <div class="text-sm line-clamp-2 opacity-80 mb-1">
              {raw(
                PostUtilities.render_content_preview(
                  @post.content,
                  PostUtilities.get_instance_domain(@post)
                )
              )}
            </div>
          <% end %>
        <% end %>
        
    <!-- Meta line -->
        <div class="flex items-center gap-2 text-xs text-base-content/50">
          <%= if @post.federated && Ecto.assoc_loaded?(@post.remote_actor) && @post.remote_actor do %>
            <span>@{@post.remote_actor.username}</span>
          <% else %>
            <%= if @post.sender do %>
              <span>@{@post.sender.handle || @post.sender.username}</span>
            <% end %>
          <% end %>
          <span>·</span>
          <.local_time datetime={@post.inserted_at} format="relative" timezone={@timezone} />
          <span>·</span>
          <span class="flex items-center gap-1">
            <.icon name="hero-heart" class="w-3 h-3" />
            {@display_like_count}
          </span>
          <span class="flex items-center gap-1">
            <.icon name="hero-chat-bubble-left" class="w-3 h-3" />
            {@display_comment_count}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions - delegate to PostUtilities where possible
  defp extract_community_name(uri), do: PostUtilities.extract_community_name_simple(uri)

  defp video_url?(url), do: PostUtilities.video_url?(url)

  defp audio_url?(url), do: PostUtilities.audio_url?(url)
end
