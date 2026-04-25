defmodule ElektrineSocialWeb.Components.Social.TimelinePost do
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
  import ElektrineWeb.Components.Social.YoutubePreview, only: [youtube_preview: 1]
  import ElektrineWeb.HtmlHelpers
  import ElektrineSocialWeb.Components.Social.PostActions
  import ElektrineSocialWeb.Components.Social.EmbeddedPost, only: [embedded_post: 1]
  import ElektrineSocialWeb.Components.Social.FollowButton, only: [local_follow_button: 1]
  import ElektrineSocialWeb.Components.Social.PostReactions, only: [post_reactions: 1]
  import ElektrineSocialWeb.Components.Social.ContentJourney, only: [content_journey: 1]
  import Elektrine.Components.User.Avatar
  import Elektrine.Components.User.UsernameEffects
  import ElektrineSocialWeb.Components.User.HoverCard

  alias Elektrine.Messaging
  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias ElektrineSocialWeb.Components.Social.PostUtilities
  alias ElektrineWeb.Platform.Integrations

  @default_image_aspect_ratio {3, 2}
  @default_video_aspect_ratio {16, 9}

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
  * `:on_navigate_profile` - Event for navigating to profile
  * `:on_image_click` - Event for opening image modal
  * `:clickable` - Whether clicking the card should open the post (default: true)
  * `:layout` - Layout variant: :timeline (default), :lemmy, or :compact
  * `:user_downvotes` - Map of post_id => boolean for downvote status (Lemmy layout)
  * `:post_interactions` - Map of post_id => interaction state for optimistic updates
  * `:reactions` - List of reactions on the post (Lemmy layout)
  * `:replies` - List of replies to display in thread preview (Lemmy layout)
  * `:user_saves` - Map of post_id => boolean for save status
  * `:post_reactions_map` - Map of post_id => reactions list for ancestor interaction cards
  * `:show_ancestor_actions` - Enables interactive actions on ancestor cards
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
  attr :remote_follow_overrides, :map, default: %{}
  attr :user_statuses, :map, default: %{}
  attr :lemmy_counts, :map, default: %{}
  attr :post_replies, :map, default: %{}
  attr :post_interactions, :map, default: %{}
  attr :post_reactions_map, :map, default: %{}
  attr :reactions, :list, default: []
  attr :replies, :list, default: []
  attr :id_prefix, :string, default: "post"
  attr :show_follow_button, :boolean, default: true
  attr :show_admin_actions, :boolean, default: true
  attr :show_post_dropdown, :boolean, default: true
  attr :show_view_button, :boolean, default: false
  attr :on_navigate_profile, :string, default: "navigate_to_profile"
  attr :on_image_click, :string, default: "open_image_modal"
  attr :on_like, :string, default: "like_post"
  attr :on_unlike, :string, default: "unlike_post"
  attr :on_comment, :string, default: "show_reply_form"
  attr :on_downvote, :string, default: "downvote_post"
  attr :on_undownvote, :string, default: "undownvote_post"
  attr :on_react, :string, default: "react_to_post"
  attr :clickable, :boolean, default: true
  attr :source, :string, default: "timeline"
  attr :resolve_reply_refs, :boolean, default: false
  attr :show_ancestor_actions, :boolean, default: false
  attr :show_quote_button, :boolean, default: true
  attr :show_save_button, :boolean, default: true
  attr :show_thread_context, :boolean, default: true
  attr :interaction_mode, :atom, default: :vote
  attr :remote_poll_vote, :map, default: nil
  attr :action_post_id, :any, default: nil
  attr :action_value_name, :string, default: "message_id"
  attr :save_action_post_id, :any, default: nil
  attr :save_action_value_name, :string, default: nil
  attr :saved_override, :any, default: nil

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

    # Resolve ancestor context (root -> parent) only for replies.
    reply_ancestors =
      if is_reply do
        resolve_reply_ancestors_for_post(
          post,
          assigns.source,
          assigns.resolve_reply_refs
        )
      else
        []
      end

    # Calculate display counts and apply optimistic interaction state for live button updates.
    {base_like_count, display_comment_count} =
      PostUtilities.get_display_counts(post, assigns.lemmy_counts, assigns.post_replies)

    post_state = current_post_interaction_state(assigns.post_interactions, post)

    display_like_count = max((base_like_count || 0) + Map.get(post_state, :like_delta, 0), 0)
    display_boost_count = max(base_share_count(post) + Map.get(post_state, :boost_delta, 0), 0)
    is_liked = Map.get(post_state, :liked, current_post_flag(assigns.user_likes, post))
    is_boosted = Map.get(post_state, :boosted, current_post_flag(assigns.user_boosts, post))

    is_saved =
      if is_nil(assigns.saved_override),
        do: current_post_flag(assigns.user_saves, post),
        else: assigns.saved_override

    assigns =
      assigns
      |> assign_new(:remote_poll_vote, fn -> nil end)
      |> assign(:is_reply, is_reply)
      |> assign(:is_gallery_post, is_gallery_post)
      |> assign(:reply_ancestors, reply_ancestors)
      |> assign(:direct_reply_target, List.last(reply_ancestors))
      |> assign(:has_thread_context, assigns.show_thread_context && reply_ancestors != [])
      |> assign(:display_like_count, display_like_count)
      |> assign(:display_boost_count, display_boost_count)
      |> assign(:display_comment_count, display_comment_count)
      |> assign(:is_liked, is_liked)
      |> assign(:is_boosted, is_boosted)
      |> assign(:is_saved, is_saved)

    ~H"""
    <div
      id={"#{@id_prefix}-entry-#{@post.id}"}
      class="space-y-2"
    >
      <div class="relative">
        <div
          id={"#{@id_prefix}-card-#{@post.id}"}
          class={[
            "card panel-card rounded-lg timeline-post-card shadow-sm max-w-full overflow-visible relative z-0 transition-shadow",
            if(@clickable, do: "cursor-pointer"),
            if(@has_thread_context, do: "timeline-thread-current-card border border-base-300/85"),
            if(@is_reply && !@has_thread_context,
              do: "timeline-thread-current-card border border-base-300/85"
            ),
            if(@is_reply,
              do:
                "border-l-2 border-l-base-300 bg-base-100/95 border-t border-r border-b border-base-300",
              else: "border border-base-300"
            )
          ]}
          data-post-id={@post.id}
          data-source={@source}
          phx-hook={if @clickable, do: "PostClick", else: nil}
        >
          <%= if @clickable do %>
            <.link
              navigate={Elektrine.Paths.post_path(@post)}
              class="hidden"
              data-post-nav-link
              tabindex="-1"
              aria-hidden="true"
            >
              Open post
            </.link>
          <% end %>

          <div class="card-body timeline-post-card-body p-4 min-w-0 overflow-visible">
            <!-- Boosted By Indicator -->
            <.boost_indicator post={@post} />

            <.inline_reply_target :if={@is_reply} target={@direct_reply_target} />
            
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
              show_post_dropdown={false}
            />
            
    <!-- Content Journey Trail -->
            <.content_journey message={@post} context={@source} />
            
    <!-- Post Content -->
            <.post_content
              post={@post}
              current_user={@current_user}
              is_gallery_post={@is_gallery_post}
              on_image_click={@on_image_click}
              remote_poll_vote={@remote_poll_vote}
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
              remote_follow_overrides={@remote_follow_overrides}
              display_like_count={@display_like_count}
              display_boost_count={@display_boost_count}
              display_comment_count={@display_comment_count}
              show_follow_button={@show_follow_button}
              show_view_button={@show_view_button}
              id_prefix={@id_prefix}
              is_liked={@is_liked}
              is_boosted={@is_boosted}
              is_saved={@is_saved}
              on_comment={@on_comment}
              show_quote_button={@show_quote_button}
              show_save_button={@show_save_button}
              action_post_id={@action_post_id}
              action_value_name={@action_value_name}
              save_action_post_id={@save_action_post_id}
              save_action_value_name={@save_action_value_name}
            />
            
    <!-- Emoji Reactions -->
            <div class="mt-2 pt-2 border-t border-base-200">
              <.post_reactions
                post_id={@post.id}
                reactions={@reactions}
                current_user={@current_user}
                size={:xs}
              />
            </div>
          </div>

          <%= if @current_user && @show_post_dropdown do %>
            <div class="absolute right-4 top-4 z-[320]">
              <.post_dropdown
                post={@post}
                current_user={@current_user}
                show_admin_actions={@show_admin_actions}
              />
            </div>
          <% end %>
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
        Elektrine.Strings.present?(booster["domain"]) &&
          Elektrine.Strings.present?(booster["username"])

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
  attr :show_post_dropdown, :boolean, default: true

  defp post_header(assigns) do
    ~H"""
    <div class="flex items-center gap-3 mb-3 overflow-visible relative z-10 pr-10">
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
      <%= if @current_user && @show_post_dropdown do %>
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

    assigns =
      assigns
      |> assign(:community_uri, community_uri)
      |> assign(:community_path, community_path(assigns.post, community_uri))

    ~H"""
    <.user_hover_card remote_actor={@post.remote_actor}>
      <.link
        navigate={"/remote/#{@post.remote_actor.username}@#{@post.remote_actor.domain}"}
        class="w-10 h-10 rounded-full block"
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
            class="font-medium hover:text-primary transition-colors duration-200 truncate"
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
            <%= if @community_path do %>
              <.link navigate={@community_path} class="link link-hover">
                {extract_community_name(@community_uri)}
              </.link>
            <% else %>
              <span>{extract_community_name(@community_uri)}</span>
            <% end %>
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
            title={"Edited #{Integrations.social_time_ago(@post.edited_at)}"}
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
          @{@post.sender.handle || @post.sender.username}@{Elektrine.Domains.default_user_handle_domain()} ·
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
            title={"Edited #{Integrations.social_time_ago(@post.edited_at)}"}
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
      class="dropdown timeline-post-dropdown dropdown-end flex-shrink-0"
      id={"post-dropdown-#{@post.id}"}
    >
      <label tabindex="0" class="btn btn-ghost btn-xs btn-square h-7 w-7 min-h-0 sm:h-8 sm:w-8">
        <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
      </label>
      <ul
        tabindex="0"
        class="dropdown-content timeline-post-dropdown-menu menu p-2 rounded-box w-52"
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

  # Reply ancestor stack component - renders root -> parent context cards with thread rails.
  attr :ancestor, :map, required: true

  defp ancestor_avatar(assigns) do
    ~H"""
    <%= if @ancestor.local_sender do %>
      <div class="w-6 h-6 flex-shrink-0">
        <.user_avatar user={@ancestor.local_sender} size="xs" />
      </div>
    <% else %>
      <%= if @ancestor.remote_actor && @ancestor.remote_actor.avatar_url do %>
        <img
          src={ensure_https(@ancestor.remote_actor.avatar_url)}
          alt=""
          class="w-6 h-6 rounded-full object-cover flex-shrink-0"
        />
      <% else %>
        <div class="w-6 h-6 rounded-full bg-base-300 flex items-center justify-center flex-shrink-0">
          <.icon name="hero-user" class="w-3.5 h-3.5 opacity-60" />
        </div>
      <% end %>
    <% end %>
    """
  end

  attr :target, :map, default: nil

  defp inline_reply_target(assigns) do
    ~H"""
    <%= if is_map(@target) do %>
      <% clickable = ancestor_clickable?(@target)
      subtitle = ancestor_author_subtitle(@target) %>
      <div class="timeline-inline-reply-target mb-3">
        <div class="mb-1 text-[11px] font-medium uppercase tracking-[0.18em] text-base-content/45">
          In reply to
        </div>

        <%= if clickable do %>
          <button
            type="button"
            class="thread-context-card timeline-inline-reply-target__card w-full text-left"
            {ancestor_click_attrs(@target)}
          >
            <.inline_reply_target_content target={@target} subtitle={subtitle} />
          </button>
        <% else %>
          <div class="timeline-inline-reply-target__card">
            <.inline_reply_target_content target={@target} subtitle={subtitle} />
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr :target, :map, required: true
  attr :subtitle, :string, default: nil

  defp inline_reply_target_content(assigns) do
    ~H"""
    <div class="flex items-start gap-3 rounded-2xl border border-base-300/80 bg-base-200/45 px-3 py-2.5 transition-colors hover:bg-base-200/65">
      <.ancestor_avatar ancestor={@target} />
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2 min-w-0 text-sm">
          <span class={["truncate font-medium", ancestor_author_class(@target.author_info.type)]}>
            {@target.author_info.name}
          </span>
          <%= if @subtitle do %>
            <span class="truncate text-xs text-base-content/55">{@subtitle}</span>
          <% end %>
          <%= if ancestor_clickable?(@target) do %>
            <span class="ml-auto flex-shrink-0 text-xs text-base-content/45">Open parent</span>
          <% end %>
        </div>

        <div class="mt-1 text-sm text-base-content/75 line-clamp-3 break-words">
          <%= if @target.preview_content do %>
            {raw(
              PostUtilities.render_content_preview(
                @target.preview_content,
                @target.instance_domain
              )
            )}
          <% else %>
            Previous post
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp ancestor_author_subtitle(ancestor) when is_map(ancestor) do
    cond do
      is_map(ancestor.local_sender) ->
        "@#{ancestor.local_sender.handle || ancestor.local_sender.username}@#{Elektrine.Domains.default_user_handle_domain()}"

      is_map(ancestor.remote_actor) ->
        "@#{ancestor.remote_actor.username}@#{ancestor.remote_actor.domain}"

      is_binary(ancestor.activitypub_ref) ->
        case URI.parse(ancestor.activitypub_ref) do
          %{host: host} when is_binary(host) and host != "" -> "on #{host}"
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp ancestor_author_subtitle(_), do: nil

  defp resolve_reply_ancestors_for_post(post, source, resolve_reply_refs) when is_map(post) do
    max_depth = reply_ancestor_max_depth(source)
    should_resolve_refs = should_resolve_reply_refs?(source, resolve_reply_refs)
    allow_db_lookups = allow_ancestor_db_lookups?(source)

    cache_key =
      {
        source || "timeline",
        max_depth,
        should_resolve_refs,
        allow_db_lookups,
        Map.get(post, :id),
        Map.get(post, :reply_to_id),
        Map.get(post, :activitypub_id),
        Map.get(post, :activitypub_url),
        metadata_in_reply_to(post),
        Map.get(post, :updated_at),
        Map.get(post, :edited_at)
      }

    cache = Process.get(:timeline_post_reply_ancestor_cache, %{})

    case Map.fetch(cache, cache_key) do
      {:ok, ancestors} ->
        ancestors

      :error ->
        ancestors =
          resolve_reply_ancestors(post, should_resolve_refs, max_depth, allow_db_lookups)

        next_cache =
          cache
          |> maybe_reset_reply_ancestor_cache()
          |> Map.put(cache_key, ancestors)

        Process.put(:timeline_post_reply_ancestor_cache, next_cache)
        ancestors
    end
  end

  defp resolve_reply_ancestors_for_post(_, _, _), do: []

  # Keep reply ancestor lookups cheap on high-volume feeds.
  defp reply_ancestor_max_depth(source)
       when source in ["timeline", "overview", "hashtag", "remote_profile"],
       do: 3

  defp reply_ancestor_max_depth(_), do: 8

  # External reference resolution can be expensive and is not required for feed readability.
  defp should_resolve_reply_refs?(source, _resolve_reply_refs)
       when source in ["timeline", "overview", "hashtag", "remote_profile"] do
    false
  end

  defp should_resolve_reply_refs?(_source, resolve_reply_refs), do: resolve_reply_refs

  # Keep feed rendering free of synchronous database lookups.
  defp allow_ancestor_db_lookups?(_source), do: false

  defp maybe_reset_reply_ancestor_cache(cache) when is_map(cache) do
    if map_size(cache) >= 256 do
      %{}
    else
      cache
    end
  end

  defp maybe_reset_reply_ancestor_cache(_), do: %{}

  defp resolve_reply_ancestors(post, resolve_reply_refs, max_depth, allow_db_lookups)

  defp resolve_reply_ancestors(post, resolve_reply_refs, max_depth, allow_db_lookups)
       when is_map(post) and max_depth > 0 do
    {initial_message, initial_ref, initial_author, initial_content} =
      ancestor_seed(post, resolve_reply_refs, allow_db_lookups)

    do_resolve_reply_ancestors(
      initial_message,
      initial_ref,
      initial_author,
      initial_content,
      [],
      MapSet.new(),
      max_depth,
      resolve_reply_refs,
      allow_db_lookups
    )
  end

  defp resolve_reply_ancestors(_, _, _, _), do: []

  defp do_resolve_reply_ancestors(
         _,
         _,
         _,
         _,
         acc,
         _seen,
         depth,
         _resolve_reply_refs,
         _allow_db_lookups
       )
       when depth <= 0,
       do: acc

  defp do_resolve_reply_ancestors(
         nil,
         nil,
         _fallback_author,
         _fallback_content,
         acc,
         _seen,
         _depth,
         _resolve_reply_refs,
         _allow_db_lookups
       ),
       do: acc

  defp do_resolve_reply_ancestors(
         message,
         ref,
         fallback_author,
         fallback_content,
         acc,
         seen,
         depth,
         resolve_reply_refs,
         allow_db_lookups
       ) do
    message =
      preload_or_resolve_ancestor_message(
        message,
        ref,
        resolve_reply_refs,
        allow_db_lookups
      )

    seen_key = ancestor_seen_key(message, ref)

    cond do
      is_nil(seen_key) ->
        acc

      MapSet.member?(seen, seen_key) ->
        acc

      true ->
        entry =
          build_reply_ancestor_entry(
            message,
            ref,
            fallback_author,
            fallback_content,
            allow_db_lookups
          )

        {next_message, next_ref, next_author, next_content} =
          next_ancestor_state(message, resolve_reply_refs, allow_db_lookups)

        next_acc =
          if entry do
            [entry | acc]
          else
            acc
          end

        do_resolve_reply_ancestors(
          next_message,
          next_ref,
          next_author,
          next_content,
          next_acc,
          MapSet.put(seen, seen_key),
          depth - 1,
          resolve_reply_refs,
          allow_db_lookups
        )
    end
  end

  defp ancestor_seed(post, resolve_reply_refs, allow_db_lookups) do
    metadata_ref = metadata_in_reply_to(post)
    metadata_author = metadata_in_reply_to_author(post)
    metadata_content = metadata_in_reply_to_content(post)

    loaded_reply =
      if Map.has_key?(post, :reply_to) && assoc_loaded_map?(post.reply_to),
        do: post.reply_to,
        else: nil

    local_parent_id = normalize_local_id(Map.get(post, :reply_to_id))

    cond do
      is_map(loaded_reply) ->
        {preload_ancestor_message(loaded_reply, allow_db_lookups), metadata_ref, metadata_author,
         metadata_content}

      allow_db_lookups && is_integer(local_parent_id) ->
        {fetch_local_ancestor(local_parent_id), metadata_ref, metadata_author, metadata_content}

      allow_db_lookups && resolve_reply_refs && is_binary(metadata_ref) ->
        {resolve_ancestor_ref(metadata_ref), metadata_ref, metadata_author, metadata_content}

      is_binary(metadata_ref) ->
        {nil, metadata_ref, metadata_author, metadata_content}

      true ->
        {nil, nil, nil, nil}
    end
  end

  defp preload_or_resolve_ancestor_message(message, _ref, _resolve_reply_refs, allow_db_lookups)
       when is_map(message),
       do: preload_ancestor_message(message, allow_db_lookups)

  defp preload_or_resolve_ancestor_message(nil, ref, true, true) when is_binary(ref),
    do: resolve_ancestor_ref(ref)

  defp preload_or_resolve_ancestor_message(_, _, _, _), do: nil

  defp next_ancestor_state(message, resolve_reply_refs, allow_db_lookups) when is_map(message) do
    metadata_ref = metadata_in_reply_to(message)
    metadata_author = metadata_in_reply_to_author(message)
    metadata_content = metadata_in_reply_to_content(message)

    loaded_parent =
      if Map.has_key?(message, :reply_to) && assoc_loaded_map?(message.reply_to) do
        preload_ancestor_message(message.reply_to, allow_db_lookups)
      else
        nil
      end

    local_parent_id = normalize_local_id(Map.get(message, :reply_to_id))

    local_parent =
      if allow_db_lookups && is_nil(loaded_parent) && is_integer(local_parent_id) do
        fetch_local_ancestor(local_parent_id)
      else
        nil
      end

    resolved_parent =
      if allow_db_lookups && is_nil(loaded_parent) && is_nil(local_parent) && resolve_reply_refs &&
           is_binary(metadata_ref) do
        resolve_ancestor_ref(metadata_ref)
      else
        nil
      end

    {loaded_parent || local_parent || resolved_parent, metadata_ref, metadata_author,
     metadata_content}
  end

  defp next_ancestor_state(_, _, _), do: {nil, nil, nil, nil}

  defp build_reply_ancestor_entry(
         message,
         ref,
         fallback_author,
         fallback_content,
         allow_db_lookups
       ) do
    local_id =
      if is_map(message) do
        normalize_local_id(Map.get(message, :id))
      else
        nil
      end

    activitypub_ref =
      if is_map(message) do
        normalize_in_reply_to_ref(Map.get(message, :activitypub_id)) ||
          normalize_in_reply_to_ref(Map.get(message, :activitypub_url)) ||
          normalize_in_reply_to_ref(ref)
      else
        normalize_in_reply_to_ref(ref)
      end

    {click_event, click_url, click_id} =
      cond do
        is_integer(local_id) ->
          {"navigate_to_post", nil, local_id}

        is_binary(activitypub_ref) ->
          {"navigate_to_remote_post", activitypub_ref, nil}

        true ->
          {nil, nil, nil}
      end

    author_info = ancestor_author_info(message, fallback_author, activitypub_ref)

    preview_content =
      ancestor_preview_content(message, fallback_content) ||
        local_ancestor_preview_content(activitypub_ref, allow_db_lookups)

    instance_domain = ancestor_instance_domain(message, activitypub_ref)

    local_sender =
      if(is_map(message) && assoc_loaded_map?(Map.get(message, :sender)),
        do: message.sender,
        else: nil
      )

    remote_actor =
      if(is_map(message) && assoc_loaded_map?(Map.get(message, :remote_actor)),
        do: message.remote_actor,
        else: nil
      )

    interaction_keys =
      [
        normalize_in_reply_to_ref(
          if(is_map(message), do: Map.get(message, :activitypub_id), else: nil)
        ),
        if(is_integer(local_id), do: to_string(local_id), else: nil)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    has_payload =
      is_integer(local_id) ||
        is_binary(activitypub_ref) ||
        is_binary(preview_content) ||
        (is_map(author_info) && author_info.name != "a post")

    if has_payload do
      %{
        local_id: local_id,
        click_event: click_event,
        click_url: click_url,
        click_id: click_id,
        author_info: author_info,
        activitypub_ref: activitypub_ref,
        preview_content: preview_content,
        instance_domain: instance_domain,
        local_sender: local_sender,
        remote_actor: remote_actor,
        like_count: if(is_map(message), do: Map.get(message, :like_count, 0) || 0, else: 0),
        boost_count: if(is_map(message), do: Map.get(message, :share_count, 0) || 0, else: 0),
        reply_count: if(is_map(message), do: Map.get(message, :reply_count, 0) || 0, else: 0),
        interaction_keys: interaction_keys
      }
    else
      nil
    end
  end

  defp ancestor_author_info(message, fallback_author, activitypub_ref) when is_map(message) do
    cond do
      assoc_loaded_map?(Map.get(message, :remote_actor)) ->
        remote_actor = message.remote_actor
        %{name: "@#{remote_actor.username}@#{remote_actor.domain}", type: :federated}

      assoc_loaded_map?(Map.get(message, :sender)) ->
        sender = message.sender

        %{
          name:
            "@#{sender.handle || sender.username}@#{Elektrine.Domains.default_user_handle_domain()}",
          type: :local
        }

      is_binary(fallback_author) ->
        normalize_reply_author_info(fallback_author, activitypub_ref)

      is_binary(activitypub_ref) ->
        %{name: infer_reply_label_from_url(activitypub_ref) || "a post", type: :external}

      true ->
        %{name: "a post", type: :unknown}
    end
  end

  defp ancestor_author_info(_message, fallback_author, activitypub_ref)
       when is_binary(fallback_author) do
    normalize_reply_author_info(fallback_author, activitypub_ref)
  end

  defp ancestor_author_info(_message, _fallback_author, activitypub_ref)
       when is_binary(activitypub_ref) do
    %{name: infer_reply_label_from_url(activitypub_ref) || "a post", type: :external}
  end

  defp ancestor_author_info(_, _, _), do: %{name: "a post", type: :unknown}

  defp ancestor_preview_content(message, fallback_content) when is_map(message) do
    message_content = Map.get(message, :content)

    cond do
      Elektrine.Strings.present?(message_content) ->
        message_content

      Elektrine.Strings.present?(fallback_content) ->
        fallback_content

      true ->
        nil
    end
  end

  defp ancestor_preview_content(_, fallback_content)
       when is_binary(fallback_content),
       do:
         if(Elektrine.Strings.present?(fallback_content),
           do: fallback_content,
           else: nil
         )

  defp ancestor_preview_content(_, _), do: nil

  defp local_ancestor_preview_content(activitypub_ref, true) when is_binary(activitypub_ref) do
    case Messaging.get_message_by_activitypub_ref(activitypub_ref) do
      %Message{} = message ->
        ancestor_preview_content(message, nil)

      _ ->
        nil
    end
  end

  defp local_ancestor_preview_content(_, _), do: nil

  defp ancestor_instance_domain(message, _activitypub_ref) when is_map(message),
    do: PostUtilities.get_instance_domain(message)

  defp ancestor_instance_domain(_, activitypub_ref) when is_binary(activitypub_ref) do
    case URI.parse(activitypub_ref) do
      %{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp ancestor_instance_domain(_, _), do: nil

  defp reply_reaction_surface(reply, post_reactions_map) when is_map(post_reactions_map) do
    case reply_reaction_target(reply) do
      {nil, _value_name, _keys, _actor_uri} ->
        %{target_id: nil, value_name: "post_id", reactions: [], actor_uri: nil}

      {target_id, value_name, lookup_keys, actor_uri} ->
        %{
          target_id: target_id,
          value_name: value_name,
          reactions: reactions_for_keys(post_reactions_map, lookup_keys),
          actor_uri: actor_uri
        }
    end
  end

  defp reply_reaction_surface(_reply, _post_reactions_map),
    do: %{target_id: nil, value_name: "post_id", reactions: [], actor_uri: nil}

  defp reply_reaction_target(%{id: id} = reply) when is_integer(id) do
    {id, "message_id", [Integer.to_string(id), id], reply_actor_uri(reply)}
  end

  defp reply_reaction_target(%{"id" => id} = reply) when is_integer(id) do
    {id, "message_id", [Integer.to_string(id), id], reply_actor_uri(reply)}
  end

  defp reply_reaction_target(%{"_local_message_id" => id} = reply) when is_integer(id) do
    {id, "message_id", [Integer.to_string(id), id], reply_actor_uri(reply)}
  end

  defp reply_reaction_target(%{_local_message_id: id} = reply) when is_integer(id) do
    {id, "message_id", [Integer.to_string(id), id], reply_actor_uri(reply)}
  end

  defp reply_reaction_target(%{"id" => id} = reply) when is_binary(id) and id != "" do
    case Integer.parse(id) do
      {local_id, ""} ->
        {local_id, "message_id", [id, local_id], reply_actor_uri(reply)}

      _ ->
        {id, "post_id", [id], reply_actor_uri(reply)}
    end
  end

  defp reply_reaction_target(%{id: id} = reply) when is_binary(id) and id != "" do
    case Integer.parse(id) do
      {local_id, ""} ->
        {local_id, "message_id", [id, local_id], reply_actor_uri(reply)}

      _ ->
        {id, "post_id", [id], reply_actor_uri(reply)}
    end
  end

  defp reply_reaction_target(%{"ap_id" => ap_id} = reply) when is_binary(ap_id) and ap_id != "" do
    {ap_id, "post_id", [ap_id], reply_actor_uri(reply)}
  end

  defp reply_reaction_target(%{ap_id: ap_id} = reply) when is_binary(ap_id) and ap_id != "" do
    {ap_id, "post_id", [ap_id], reply_actor_uri(reply)}
  end

  defp reply_reaction_target(_), do: {nil, "post_id", [], nil}

  defp reply_actor_uri(%{"actor_id" => actor_uri}) when is_binary(actor_uri) and actor_uri != "",
    do: actor_uri

  defp reply_actor_uri(%{actor_id: actor_uri}) when is_binary(actor_uri) and actor_uri != "",
    do: actor_uri

  defp reply_actor_uri(%{"actor_uri" => actor_uri})
       when is_binary(actor_uri) and actor_uri != "",
       do: actor_uri

  defp reply_actor_uri(%{actor_uri: actor_uri}) when is_binary(actor_uri) and actor_uri != "",
    do: actor_uri

  defp reply_actor_uri(%{remote_actor: %{uri: actor_uri}})
       when is_binary(actor_uri) and actor_uri != "",
       do: actor_uri

  defp reply_actor_uri(%{"remote_actor" => %{"uri" => actor_uri}})
       when is_binary(actor_uri) and actor_uri != "",
       do: actor_uri

  defp reply_actor_uri(_), do: nil

  defp reactions_for_keys(reactions_map, keys) when is_map(reactions_map) and is_list(keys) do
    Enum.find_value(keys, [], fn key ->
      case Map.get(reactions_map, key) do
        reactions when is_list(reactions) -> reactions
        _ -> nil
      end
    end) || []
  end

  defp reactions_for_keys(_, _), do: []

  defp ancestor_clickable?(%{click_event: event, click_url: url})
       when is_binary(event) and event != "" and is_binary(url) and url != "",
       do: true

  defp ancestor_clickable?(%{click_event: event, click_id: id})
       when is_binary(event) and event != "" and not is_nil(id),
       do: true

  defp ancestor_clickable?(_), do: false

  defp ancestor_click_attrs(%{click_event: event} = ancestor)
       when is_binary(event) and event != "" do
    [{"phx-click", event}]
    |> Kernel.++(ancestor_optional_click_attr("phx-value-id", Map.get(ancestor, :click_id)))
    |> Kernel.++(ancestor_optional_click_attr("phx-value-url", Map.get(ancestor, :click_url)))
  end

  defp ancestor_click_attrs(_), do: []

  defp ancestor_optional_click_attr(name, value) when is_binary(value) and value != "",
    do: [{name, value}]

  defp ancestor_optional_click_attr(name, value) when is_integer(value),
    do: [{name, value}]

  defp ancestor_optional_click_attr(_name, _value), do: []

  defp ancestor_author_class(:federated), do: "text-primary"
  defp ancestor_author_class(:local), do: "text-error"
  defp ancestor_author_class(:external), do: "text-secondary"
  defp ancestor_author_class(_), do: ""

  defp ancestor_seen_key(message, _ref) when is_map(message) do
    cond do
      is_integer(Map.get(message, :id)) ->
        {:id, message.id}

      is_binary(Map.get(message, :activitypub_id)) ->
        {:ap, message.activitypub_id}

      true ->
        nil
    end
  end

  defp ancestor_seen_key(_, ref) when is_binary(ref), do: {:ref, ref}
  defp ancestor_seen_key(_, _), do: nil

  defp resolve_ancestor_ref(ref) when is_binary(ref) do
    cached_ancestor_message({:ref, ref}, fn ->
      ref
      |> Messaging.get_message_by_activitypub_ref()
      |> preload_ancestor_message()
    end)
  end

  defp resolve_ancestor_ref(_), do: nil

  defp fetch_local_ancestor(id) when is_integer(id) do
    cached_ancestor_message({:id, id}, fn ->
      Message
      |> Repo.get(id)
      |> preload_ancestor_message()
    end)
  end

  defp fetch_local_ancestor(_), do: nil

  defp preload_ancestor_message(%Message{} = message), do: preload_ancestor_message(message, true)
  defp preload_ancestor_message(message) when is_map(message), do: message
  defp preload_ancestor_message(_), do: nil

  defp preload_ancestor_message(%Message{} = message, allow_db_lookups)
       when is_boolean(allow_db_lookups) do
    if ancestor_associations_loaded?(message) do
      message
    else
      if allow_db_lookups do
        Repo.preload(message, [:sender, :remote_actor, :reply_to], force: false)
      else
        message
      end
    end
  end

  defp preload_ancestor_message(message, _allow_db_lookups) when is_map(message), do: message
  defp preload_ancestor_message(_, _allow_db_lookups), do: nil

  defp ancestor_associations_loaded?(%Message{} = message) do
    Ecto.assoc_loaded?(Map.get(message, :sender)) &&
      Ecto.assoc_loaded?(Map.get(message, :remote_actor)) &&
      Ecto.assoc_loaded?(Map.get(message, :reply_to))
  end

  defp cached_ancestor_message(cache_key, loader) when is_function(loader, 0) do
    cache = Process.get(:timeline_post_ancestor_message_cache, %{})

    case Map.fetch(cache, cache_key) do
      {:ok, message} ->
        message

      :error ->
        message = loader.()

        next_cache =
          cache
          |> maybe_reset_ancestor_message_cache()
          |> Map.put(cache_key, message)

        Process.put(:timeline_post_ancestor_message_cache, next_cache)
        message
    end
  end

  defp maybe_reset_ancestor_message_cache(cache) when is_map(cache) do
    if map_size(cache) >= 512 do
      %{}
    else
      cache
    end
  end

  defp maybe_reset_ancestor_message_cache(_), do: %{}

  defp assoc_loaded_map?(%Ecto.Association.NotLoaded{}), do: false
  defp assoc_loaded_map?(value) when is_map(value), do: true
  defp assoc_loaded_map?(_), do: false

  defp metadata_in_reply_to(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata")

    if is_map(metadata) do
      [
        Map.get(metadata, "inReplyTo"),
        Map.get(metadata, "in_reply_to"),
        Map.get(metadata, :inReplyTo),
        Map.get(metadata, :in_reply_to)
      ]
      |> Enum.find_value(&normalize_in_reply_to_ref/1)
    else
      nil
    end
  end

  defp metadata_in_reply_to(_), do: nil

  defp metadata_in_reply_to_author(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata")

    if is_map(metadata) do
      Map.get(metadata, "inReplyToAuthor") ||
        Map.get(metadata, "in_reply_to_author") ||
        Map.get(metadata, :inReplyToAuthor) ||
        Map.get(metadata, :in_reply_to_author)
    else
      nil
    end
  end

  defp metadata_in_reply_to_author(_), do: nil

  defp metadata_in_reply_to_content(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata")

    if is_map(metadata) do
      Map.get(metadata, "inReplyToContent") ||
        Map.get(metadata, "in_reply_to_content") ||
        Map.get(metadata, :inReplyToContent) ||
        Map.get(metadata, :in_reply_to_content)
    else
      nil
    end
  end

  defp metadata_in_reply_to_content(_), do: nil

  defp normalize_in_reply_to_ref(%{"id" => id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{"href" => href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref(%{id: id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{href: href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref([first | _]), do: normalize_in_reply_to_ref(first)

  defp normalize_in_reply_to_ref(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_in_reply_to_ref(_), do: nil

  defp normalize_local_id(value) when is_integer(value), do: value

  defp normalize_local_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_local_id(_), do: nil

  # Post content component
  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :is_gallery_post, :boolean, default: false
  attr :on_image_click, :string, default: "open_image_modal"
  attr :remote_poll_vote, :map, default: nil

  defp post_content(assigns) do
    title = resolve_federated_title(assigns.post)

    assigns =
      assigns
      |> assign_new(:remote_poll_vote, fn -> nil end)
      |> assign(:title, title)
      |> assign(:post_path, Elektrine.Paths.post_path(assigns.post))

    ~H"""
    <!-- Title -->
    <%= if @title do %>
      <.link navigate={@post_path} class="block hover:text-primary transition-colors">
        <h3 class="font-semibold text-lg mb-2 break-words leading-tight post-content">
          {@title}
          <%= if @post.auto_title do %>
            <span class="text-xs opacity-50 ml-2">(auto)</span>
          <% end %>
        </h3>
      </.link>
    <% end %>

    <!-- Content Warning Indicator -->
    <%= if Elektrine.Strings.present?(@post.content_warning) do %>
      <div class="mb-3 flex items-center gap-2 bg-warning/10 border border-warning/30 rounded-lg p-3">
        <.icon name="hero-exclamation-triangle" class="w-4 h-4 text-warning flex-shrink-0" />
        <span class="font-medium text-sm">{@post.content_warning}</span>
        <span class="badge badge-sm badge-warning ml-auto">Sensitive</span>
      </div>
    <% end %>

    <!-- Main Content -->
    <div class={"mb-3 min-w-0 #{if Elektrine.Strings.present?(@post.content_warning), do: "blur-sm hover:blur-none transition-all", else: ""}"}>
      <!-- Quoted post content -->
      <%= if @post.quoted_message_id && Ecto.assoc_loaded?(@post.quoted_message) && @post.quoted_message do %>
        <%= if Elektrine.Strings.present?(@post.content) do %>
          <div class="break-words mb-3 post-content line-clamp-4 overflow-hidden">
            {raw(render_post_content(@post))}
          </div>
        <% end %>
        <div
          id={"quoted-post-#{@post.id}-#{@post.quoted_message_id}"}
          class="border border-base-300 rounded-lg p-3 bg-base-200/30 hover:bg-base-200/50 transition-colors"
        >
          <div class="flex items-center gap-2 mb-2">
            <.icon name="hero-chat-bubble-bottom-center-text" class="w-4 h-4 text-info flex-shrink-0" />
            <span class="text-xs font-medium text-info">Quoting</span>
          </div>
          <div class="flex items-center gap-2 mb-2">
            <%= if @post.quoted_message.sender do %>
              <.user_hover_card user={@post.quoted_message.sender}>
                <.link
                  navigate={"/#{@post.quoted_message.sender.handle || @post.quoted_message.sender.username}"}
                  class="w-6 h-6"
                >
                  <.user_avatar user={@post.quoted_message.sender} size="xs" />
                </.link>
              </.user_hover_card>
              <.user_hover_card user={@post.quoted_message.sender}>
                <.link
                  navigate={"/#{@post.quoted_message.sender.handle || @post.quoted_message.sender.username}"}
                  class="font-medium text-sm hover:text-error transition-colors"
                >
                  <.username_with_effects
                    user={@post.quoted_message.sender}
                    display_name={true}
                    verified_size="xs"
                  />
                </.link>
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
                  class="font-medium text-sm hover:text-primary transition-colors"
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
                <% full_url = Elektrine.Uploads.attachment_url(media_url, @post.quoted_message) %>
                <img src={full_url} alt="" class="w-16 h-16 rounded object-cover" />
              <% end %>
              <%= if length(@post.quoted_message.media_urls) > 2 do %>
                <div class="w-16 h-16 rounded bg-base-300 flex items-center justify-center text-xs opacity-60">
                  +{length(@post.quoted_message.media_urls) - 2}
                </div>
              <% end %>
            </div>
          <% end %>
          <%= if Ecto.assoc_loaded?(@post.quoted_message.link_preview) && link_preview_success?(@post.quoted_message.link_preview) do %>
            <div class="mt-2 border border-base-300 rounded overflow-hidden">
              <a
                href={@post.quoted_message.link_preview.url}
                target="_blank"
                rel="noopener noreferrer"
                class="flex items-center gap-2 p-2 hover:bg-base-200/50 transition-colors"
              >
                <%= if @post.quoted_message.link_preview.image_url do %>
                  <img
                    id={"timeline-quoted-preview-image-#{@post.id || :erlang.phash2(@post.quoted_message.link_preview.image_url)}"}
                    src={ensure_https(@post.quoted_message.link_preview.image_url)}
                    alt=""
                    class="w-12 h-12 rounded object-cover flex-shrink-0"
                    phx-hook="ImageFallback"
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

          <.link
            navigate={quoted_post_url(@post.quoted_message)}
            class="mt-3 inline-flex items-center gap-1 text-xs text-primary hover:underline"
          >
            <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" /> Open quoted post
          </.link>
        </div>
      <% else %>
        <!-- Cross-posted content -->
        <%= if @post.shared_message_id && @post.shared_message do %>
          <%= if @post.content && @post.content != "" do %>
            <div class="break-words mb-3 post-content line-clamp-4 overflow-hidden">
              {raw(render_post_content(@post))}
            </div>
          <% end %>
          <div>
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
                do: Integrations.social_user_poll_votes(@post.poll.id, @current_user.id),
                else: [] %>
            <div class="mt-3">
              <ElektrineSocialWeb.Components.Social.PollDisplay.poll_card
                poll={@post.poll}
                message={@post}
                current_user={@current_user}
                user_votes={user_votes}
                optimistic_vote={@remote_poll_vote}
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
    has_link_preview = link_preview_success?(assigns.post.link_preview)

    youtube_url =
      if !has_link_preview && assigns.post.content,
        do: Elektrine.Social.Message.extract_youtube_embed_url(assigns.post.content),
        else: nil

    assigns = assign(assigns, :youtube_url, youtube_url)

    ~H"""
    <%= if @youtube_url do %>
      <div>
        <.youtube_preview url={@youtube_url} wrapper_class="mt-3 rounded-lg overflow-hidden" />
      </div>
    <% end %>
    """
  end

  # Content images component (images extracted from content text)
  attr :post, :map, required: true
  attr :is_gallery_post, :boolean, default: false
  attr :on_image_click, :string, default: "open_image_modal"

  defp content_images(assigns) do
    image_urls = Elektrine.Social.Message.extract_image_urls(assigns.post.content)

    assigns =
      assigns
      |> assign(:image_urls, image_urls)
      |> assign(
        :content_image_frame_style,
        media_frame_style(nil, nil, @default_image_aspect_ratio)
      )

    ~H"""
    <%= if @image_urls != [] do %>
      <div class="mt-3 space-y-2">
        <%= for {image_url, idx} <- Enum.with_index(@image_urls) do %>
          <button
            type="button"
            phx-click={@on_image_click}
            phx-value-id={@post.id}
            phx-value-url={image_url}
            phx-value-images={Jason.encode!(@image_urls)}
            phx-value-index={idx}
            phx-value-post_id={@post.id}
            class="block w-full overflow-hidden rounded-lg bg-base-200/55"
            style={@content_image_frame_style}
          >
            <img
              id={"timeline-content-image-#{@post.id}-#{idx}-#{:erlang.phash2(image_url)}"}
              src={image_url}
              alt="Image preview"
              class="h-full w-full object-contain hover:opacity-90 transition-opacity cursor-pointer"
              loading="lazy"
              phx-hook="ImageFallback"
              data-hide-target="closest"
              data-hide-selector="button"
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
    media_entries = build_media_entries(assigns.post)
    full_media_urls = Enum.map(media_entries, & &1.full_url)

    assigns =
      assigns
      |> assign(:media_entries, media_entries)
      |> assign(:full_media_urls, full_media_urls)

    ~H"""
    <%= if @media_entries != [] do %>
      <div class="mt-3 grid grid-cols-1 gap-2">
        <%= for media_entry <- @media_entries do %>
          <%= cond do %>
            <% media_entry.is_video -> %>
              <div
                class="w-full overflow-hidden rounded-lg bg-base-200/55"
                style={media_entry.frame_style}
              >
                <video
                  src={media_entry.full_url}
                  controls
                  preload="metadata"
                  class="h-full w-full object-contain"
                >
                  Your browser does not support the video tag.
                </video>
              </div>
            <% media_entry.is_audio -> %>
              <audio src={media_entry.full_url} controls preload="metadata" class="w-full">
                Your browser does not support the audio tag.
              </audio>
            <% true -> %>
              <button
                type="button"
                phx-click={@on_image_click}
                phx-value-id={@post.id}
                phx-value-url={media_entry.full_url}
                phx-value-images={Jason.encode!(@full_media_urls)}
                phx-value-index={media_entry.index}
                phx-value-post_id={@post.id}
                class="block w-full overflow-hidden rounded-lg bg-base-200/55"
                style={media_entry.frame_style}
              >
                <img
                  id={"timeline-media-image-#{@post.id}-#{media_entry.index}-#{:erlang.phash2(media_entry.full_url)}"}
                  src={media_entry.full_url}
                  alt={media_entry.alt_text}
                  width={media_entry.width}
                  height={media_entry.height}
                  class="h-full w-full object-contain cursor-pointer hover:opacity-90 transition-opacity"
                  loading="lazy"
                  phx-hook="ImageFallback"
                  data-hide-target="closest"
                  data-hide-selector="button"
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
    <%= if link_preview_success?(@post.link_preview) do %>
      <div class="mt-3 border border-base-300 rounded-lg overflow-hidden hover:border-base-300 transition-colors max-w-full">
        <a
          href={@post.link_preview.url}
          target="_blank"
          rel="noopener noreferrer"
          class="block min-w-0"
        >
          <%= if @post.link_preview.image_url do %>
            <div class="aspect-video bg-base-50">
              <img
                id={"timeline-link-preview-image-#{@post.id || :erlang.phash2(@post.link_preview.image_url)}"}
                src={ensure_https(@post.link_preview.image_url)}
                alt={@post.link_preview.title || ""}
                class="w-full h-full object-cover"
                phx-hook="ImageFallback"
                data-hide-target="parent"
              />
            </div>
          <% end %>
          <div class="p-3 min-w-0">
            <div class="flex items-center gap-2 mb-2">
              <%= if @post.link_preview.favicon_url do %>
                <img
                  id={"timeline-link-preview-favicon-#{@post.id || :erlang.phash2(@post.link_preview.favicon_url)}"}
                  src={ensure_https(@post.link_preview.favicon_url)}
                  alt=""
                  class="w-4 h-4 flex-shrink-0"
                  phx-hook="ImageFallback"
                />
              <% end %>
              <span class="text-xs text-base-content/60 truncate">
                {@post.link_preview.site_name || URI.parse(@post.link_preview.url).host}
              </span>
            </div>
            <%= if @post.link_preview.title do %>
              <h4 class="font-medium text-sm mb-1 break-words">
                {preview_display_text(@post.link_preview.title, 100)}
              </h4>
            <% end %>
            <%= if @post.link_preview.description do %>
              <p class="text-xs text-base-content/70 break-words">
                {preview_display_text(@post.link_preview.description, 200)}
              </p>
            <% end %>
          </div>
        </a>
      </div>
    <% end %>
    """
  end

  defp build_media_entries(post) do
    metadata = media_metadata(post)
    alt_texts = media_alt_texts(metadata)
    attachments = attachment_metadata(metadata)

    (post.media_urls || [])
    |> Enum.with_index()
    |> Enum.reduce([], fn {media_url, index}, entries ->
      case Elektrine.Uploads.attachment_url(media_url, post) do
        full_url when is_binary(full_url) and full_url != "" ->
          {width, height} = media_dimensions(metadata, attachments, index)
          is_video = video_url?(full_url)
          is_audio = audio_url?(full_url)

          fallback_ratio =
            if is_video, do: @default_video_aspect_ratio, else: @default_image_aspect_ratio

          [
            %{
              alt_text:
                Map.get(alt_texts, to_string(index)) ||
                  attachment_alt_text(Enum.at(attachments, index)) ||
                  "Posted media",
              frame_style: media_frame_style(width, height, fallback_ratio),
              full_url: full_url,
              height: height,
              index: index,
              is_audio: is_audio,
              is_video: is_video,
              width: width
            }
            | entries
          ]

        _ ->
          entries
      end
    end)
    |> Enum.reverse()
  end

  defp media_metadata(post) do
    Map.get(post, :media_metadata) || Map.get(post, "media_metadata") || %{}
  end

  defp media_alt_texts(metadata) when is_map(metadata) do
    case Map.get(metadata, "alt_texts") || Map.get(metadata, :alt_texts) do
      alt_texts when is_map(alt_texts) -> alt_texts
      _ -> %{}
    end
  end

  defp media_alt_texts(_metadata), do: %{}

  defp attachment_metadata(metadata) when is_map(metadata) do
    case Map.get(metadata, "attachments") || Map.get(metadata, :attachments) do
      attachments when is_list(attachments) ->
        Enum.filter(attachments, &is_map/1)

      _ ->
        []
    end
  end

  defp attachment_metadata(_metadata), do: []

  defp media_dimensions(metadata, attachments, index) do
    attachment = Enum.at(attachments, index)

    width =
      attachment_dimension(attachment, "width") ||
        legacy_media_dimension(metadata, "widths", index)

    height =
      attachment_dimension(attachment, "height") ||
        legacy_media_dimension(metadata, "heights", index)

    {width, height}
  end

  defp attachment_dimension(attachment, key) when is_map(attachment) do
    atom_key =
      case key do
        "width" -> :width
        "height" -> :height
      end

    positive_integer(Map.get(attachment, key) || Map.get(attachment, atom_key))
  end

  defp attachment_dimension(_attachment, _key), do: nil

  defp attachment_alt_text(attachment) when is_map(attachment) do
    case Map.get(attachment, "alt_text") || Map.get(attachment, :alt_text) do
      alt_text when is_binary(alt_text) and alt_text != "" -> alt_text
      _ -> nil
    end
  end

  defp attachment_alt_text(_attachment), do: nil

  defp legacy_media_dimension(metadata, key, index) when is_map(metadata) do
    atom_key =
      case key do
        "widths" -> :widths
        "heights" -> :heights
      end

    case Map.get(metadata, key) || Map.get(metadata, atom_key) do
      values when is_map(values) ->
        positive_integer(Map.get(values, to_string(index)) || Map.get(values, index))

      values when is_list(values) ->
        positive_integer(Enum.at(values, index))

      _ ->
        nil
    end
  end

  defp legacy_media_dimension(_metadata, _key, _index), do: nil

  defp media_frame_style(width, height, fallback_ratio) do
    {aspect_width, aspect_height} =
      case {positive_integer(width), positive_integer(height)} do
        {nil, nil} -> fallback_ratio
        {nil, _} -> fallback_ratio
        {_, nil} -> fallback_ratio
        {valid_width, valid_height} -> {valid_width, valid_height}
      end

    "aspect-ratio: #{aspect_width} / #{aspect_height};"
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  # Post footer with actions
  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :user_likes, :map, default: %{}
  attr :user_boosts, :map, default: %{}
  attr :user_saves, :map, default: %{}
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :remote_follow_overrides, :map, default: %{}
  attr :display_like_count, :integer, default: 0
  attr :display_boost_count, :integer, default: 0
  attr :display_comment_count, :integer, default: 0
  attr :show_follow_button, :boolean, default: true
  attr :show_view_button, :boolean, default: false
  attr :is_liked, :boolean, default: false
  attr :is_boosted, :boolean, default: false
  attr :is_saved, :boolean, default: false
  attr :on_comment, :string, default: "show_reply_form"
  attr :show_quote_button, :boolean, default: true
  attr :show_save_button, :boolean, default: true
  attr :action_post_id, :any, default: nil
  attr :action_value_name, :string, default: "message_id"
  attr :save_action_post_id, :any, default: nil
  attr :save_action_value_name, :string, default: nil
  attr :id_prefix, :string, default: "post"

  defp post_footer(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-between gap-y-2 gap-x-1 pt-2 border-t border-base-300">
      <div class="flex items-center gap-1 flex-shrink-0">
        <.post_actions
          post_id={@action_post_id || @post.id}
          current_user={@current_user}
          is_liked={@is_liked}
          is_boosted={@is_boosted}
          is_saved={@is_saved}
          like_count={@display_like_count}
          comment_count={@display_comment_count}
          boost_count={@display_boost_count}
          quote_count={@post.quote_count || 0}
          on_comment={@on_comment}
          show_quote={@show_quote_button}
          show_save={@show_save_button}
          value_name={@action_value_name}
          save_post_id={@save_action_post_id || @post.id}
          save_value_name={@save_action_value_name || "message_id"}
          dom_id_prefix={"#{@id_prefix}-actions-#{@post.id}"}
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
            <.link
              navigate={Elektrine.Paths.post_path(@post)}
              class="btn btn-ghost btn-xs px-1.5 h-7 min-h-0 sm:px-2 sm:btn-sm"
              title="View full post"
            >
              <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3 sm:w-4 sm:h-4" />
            </.link>
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
          remote_follow_overrides={@remote_follow_overrides}
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
  attr :remote_follow_overrides, :map, default: %{}

  defp follow_actions(assigns) do
    ~H"""
    <%= if @post.federated && @post.remote_actor do %>
      <% follow_state =
        remote_follow_button_state(
          @remote_follow_overrides,
          @user_follows,
          @pending_follows,
          @post.remote_actor.id
        )

      is_following = follow_state == "following"
      is_pending = follow_state == "pending" %>
      <div class="flex items-center gap-1">
        <button
          id={"timeline-remote-follow-#{@post.id}-#{@post.remote_actor.id}"}
          phx-click="toggle_follow_remote"
          phx-value-remote_actor_id={@post.remote_actor.id}
          phx-hook="RemoteFollowButton"
          data-remote-actor-id={@post.remote_actor.id}
          data-follow-state={follow_state}
          data-follow-variant="timeline"
          class={[
            "btn btn-xs px-1.5 h-7 min-h-0 sm:px-2 sm:btn-sm phx-click-loading:pointer-events-none phx-click-loading:cursor-wait phx-click-loading:opacity-70",
            cond do
              is_following ->
                "btn-ghost"

              is_pending ->
                "btn-ghost"

              true ->
                "btn-secondary phx-click-loading:bg-base-200 phx-click-loading:text-base-content"
            end
          ]}
          type="button"
        >
          <span class="inline-flex items-center">
            <span
              data-follow-display="following"
              class={if(follow_state != "following", do: "hidden")}
            >
              <span class="inline-flex items-center">
                <.icon name="hero-user-minus" class="w-3 h-3 sm:w-4 sm:h-4" />
                <span class="text-[10px] sm:text-sm ml-0.5 sm:ml-1 hidden min-[320px]:inline">
                  Unfollow
                </span>
              </span>
            </span>
            <span
              data-follow-display="pending"
              class={if(follow_state != "pending", do: "hidden")}
            >
              <span class="inline-flex items-center">
                <.icon name="hero-clock" class="w-3 h-3 sm:w-4 sm:h-4" />
                <span class="text-[10px] sm:text-sm ml-0.5 sm:ml-1 hidden min-[320px]:inline">
                  Requested
                </span>
              </span>
            </span>
            <span
              data-follow-display="none"
              class={if(follow_state != "none", do: "hidden")}
            >
              <span class="inline-flex items-center">
                <.icon name="hero-user-plus" class="w-3 h-3 sm:w-4 sm:h-4" />
                <span class="text-[10px] sm:text-sm ml-0.5 sm:ml-1 hidden min-[320px]:inline">
                  Follow
                </span>
              </span>
            </span>
          </span>
        </button>
      </div>
    <% end %>

    <%= if !@post.federated && @post.sender && @post.sender.id != @current_user.id do %>
      <div class="flex items-center gap-1">
        <.local_follow_button user_id={@post.sender.id} user_follows={@user_follows} />
      </div>
    <% end %>
    """
  end

  defp remote_follow_button_state(
         remote_follow_overrides,
         user_follows,
         pending_follows,
         remote_actor_id
       ) do
    case remote_follow_override_state(remote_follow_overrides, remote_actor_id) do
      state when state in ["following", "pending", "none"] ->
        state

      _ ->
        cond do
          Map.get(user_follows, {:remote, remote_actor_id}, false) ||
              Map.get(user_follows, remote_actor_id, false) ->
            "following"

          Map.get(pending_follows, {:remote, remote_actor_id}, false) ||
              Map.get(pending_follows, remote_actor_id, false) ->
            "pending"

          true ->
            "none"
        end
    end
  end

  defp remote_follow_override_state(remote_follow_overrides, remote_actor_id)
       when is_map(remote_follow_overrides) do
    case Map.get(remote_follow_overrides, remote_actor_id) ||
           Map.get(remote_follow_overrides, {:remote, remote_actor_id}) do
      state when is_atom(state) -> Atom.to_string(state)
      state -> state
    end
  end

  defp remote_follow_override_state(_, _), do: nil

  defp current_post_interaction_state(post_interactions, post) do
    interaction_keys(post)
    |> Enum.find_value(%{like_delta: 0, boost_delta: 0}, fn key ->
      Map.get(post_interactions, key)
    end)
  end

  defp current_post_flag(flag_map, post) when is_map(flag_map) do
    interaction_keys(post)
    |> Enum.any?(&Map.get(flag_map, &1, false))
  end

  defp current_post_flag(_, _), do: false

  defp interaction_keys(post) do
    [post.activitypub_id, Integer.to_string(post.id), post.id]
    |> Enum.reject(&is_nil/1)
  end

  defp base_share_count(post) when is_map(post) do
    cond do
      is_integer(Map.get(post, :share_count)) ->
        Map.get(post, :share_count)

      is_integer(Map.get(post, "share_count")) ->
        Map.get(post, "share_count")

      is_map(Map.get(post, "shares")) ->
        Map.get(Map.get(post, "shares"), "totalItems", 0)

      is_map(Map.get(post, "sharesCount")) ->
        Map.get(Map.get(post, "sharesCount"), "totalItems", 0)

      is_integer(Map.get(post, "announcesCount")) ->
        Map.get(post, "announcesCount")

      true ->
        0
    end
  end

  defp base_share_count(_), do: 0

  # Lemmy/Reddit style layout with vote column
  defp render_lemmy_layout(assigns) do
    post = assigns.post
    post_id = post.activitypub_id || to_string(post.id)

    # Get interaction state
    post_state =
      [post.activitypub_id, Integer.to_string(post.id), post.id]
      |> Enum.reject(&is_nil/1)
      |> Enum.find_value(%{liked: false, downvoted: false, like_delta: 0}, fn key ->
        Map.get(assigns.post_interactions, key)
      end)

    like_only_mode = assigns.interaction_mode == :like_only

    # Prefer the explicit community vote state used by the remote post surface,
    # while still supporting overview's existing user_likes/user_downvotes maps.
    current_vote =
      if like_only_mode do
        nil
      else
        case Map.get(post_state, :vote) do
          vote when vote in ["up", "down"] -> vote
          _ -> nil
        end
      end

    raw_is_liked =
      case current_vote do
        "up" -> true
        _ -> Map.get(assigns.user_likes, post.id, Map.get(post_state, :liked, false))
      end

    raw_is_downvoted =
      case current_vote do
        "down" -> true
        _ -> Map.get(assigns.user_downvotes, post.id, Map.get(post_state, :downvoted, false))
      end

    {is_liked, is_downvoted} =
      cond do
        like_only_mode ->
          {raw_is_liked, false}

        current_vote == "up" ->
          {true, false}

        current_vote == "down" ->
          {false, true}

        raw_is_liked and raw_is_downvoted ->
          {false, false}

        true ->
          {raw_is_liked, raw_is_downvoted}
      end

    lemmy_counts = Map.get(assigns.lemmy_counts, post.activitypub_id)
    is_vote_post = PostUtilities.lemmy_vote_post?(post)

    base_count =
      cond do
        like_only_mode && is_integer(post.like_count) ->
          post.like_count

        like_only_mode && is_integer(post.score) ->
          post.score

        like_only_mode && is_map(lemmy_counts) && is_integer(Map.get(lemmy_counts, :score)) ->
          Map.get(lemmy_counts, :score)

        like_only_mode && ((post.upvotes || 0) != 0 or (post.downvotes || 0) != 0) ->
          (post.upvotes || 0) - (post.downvotes || 0)

        is_vote_post &&
          is_map(lemmy_counts) &&
            (Map.get(lemmy_counts, :upvotes, 0) != 0 or
               Map.get(lemmy_counts, :downvotes, 0) != 0) ->
          Map.get(lemmy_counts, :upvotes, 0) - Map.get(lemmy_counts, :downvotes, 0)

        is_vote_post && ((post.upvotes || 0) != 0 or (post.downvotes || 0) != 0) ->
          (post.upvotes || 0) - (post.downvotes || 0)

        is_vote_post && ((post.like_count || 0) != 0 or (post.dislike_count || 0) != 0) ->
          (post.like_count || 0) - (post.dislike_count || 0)

        is_vote_post && is_map(lemmy_counts) && is_integer(Map.get(lemmy_counts, :score)) &&
            Map.get(lemmy_counts, :score) != 0 ->
          Map.get(lemmy_counts, :score)

        is_vote_post && is_integer(post.score) && post.score != 0 ->
          post.score

        is_vote_post && is_integer(post.like_count) && post.like_count != 0 ->
          post.like_count

        is_vote_post && is_integer(post.score) && post.score != 0 ->
          post.score

        !is_vote_post && is_integer(post.like_count) ->
          post.like_count

        !is_vote_post && is_integer(post.score) ->
          post.score

        is_map(lemmy_counts) && is_integer(Map.get(lemmy_counts, :score)) ->
          Map.get(lemmy_counts, :score)

        true ->
          nil
      end

    score_delta =
      if like_only_mode do
        Map.get(post_state, :like_delta, 0)
      else
        if is_vote_post do
          Map.get(post_state, :vote_delta, 0)
        else
          Map.get(post_state, :like_delta, 0)
        end
      end

    score = if is_integer(base_count), do: base_count + score_delta, else: nil
    score_available = is_integer(score)

    # Prefer attached media, but fall back to link preview images for link submissions.
    image_urls = PostUtilities.filter_image_urls(post.media_urls || [])
    has_image = !Enum.empty?(image_urls)
    image_url = if has_image, do: thumbnail_url(hd(image_urls), 96), else: nil

    external_link = PostUtilities.detect_external_link(post)
    resolved_link_preview = Map.get(post, :link_preview)

    preview_image_url =
      if link_preview_success?(resolved_link_preview) and
           Elektrine.Strings.present?(resolved_link_preview.image_url) do
        ensure_https(resolved_link_preview.image_url)
      else
        nil
      end

    thumbnail_image_url = image_url || preview_image_url
    has_thumbnail_image = is_binary(thumbnail_image_url) and thumbnail_image_url != ""

    # Resolve title with stable fallbacks. Some federated community posts persist title on
    # the message while others only expose it via metadata.
    title = resolve_federated_title(post)
    community_uri = PostUtilities.community_actor_uri(post)

    # Reply count
    local_reply_count = length(assigns.replies)

    remote_reply_count =
      cond do
        is_map(lemmy_counts) ->
          Map.get(lemmy_counts, :comments, 0)

        is_integer(get_in(post.media_metadata || %{}, ["remote_engagement", "replies"])) ->
          get_in(post.media_metadata || %{}, ["remote_engagement", "replies"])

        is_integer(post.reply_count) ->
          post.reply_count

        true ->
          0
      end

    reply_count = max(local_reply_count, remote_reply_count)

    reaction_keys =
      [post.activitypub_id, Integer.to_string(post.id), post.id]
      |> Enum.reject(&is_nil/1)

    reactions =
      case reactions_for_keys(assigns.post_reactions_map, reaction_keys) do
        [] -> assigns.reactions
        live_reactions -> live_reactions
      end

    # Format reactions
    current_user_id = if assigns.current_user, do: assigns.current_user.id, else: nil
    formatted_reactions = PostUtilities.format_reactions(reactions, current_user_id)

    assigns =
      assigns
      |> assign(:post_id, post_id)
      |> assign(:is_liked, is_liked)
      |> assign(:is_downvoted, is_downvoted)
      |> assign(:score, score)
      |> assign(:score_available, score_available)
      |> assign(:is_vote_post, is_vote_post)
      |> assign(:like_only_mode, like_only_mode)
      |> assign(:has_image, has_image)
      |> assign(:image_url, image_url)
      |> assign(:image_urls, image_urls)
      |> assign(:preview_image_url, preview_image_url)
      |> assign(:thumbnail_image_url, thumbnail_image_url)
      |> assign(:has_thumbnail_image, has_thumbnail_image)
      |> assign(:title, title)
      |> assign(:community_uri, community_uri)
      |> assign(:community_path, community_path(post, community_uri))
      |> assign(:community_label, PostUtilities.extract_community_name(community_uri))
      |> assign(:external_link, external_link)
      |> assign(:resolved_link_preview, resolved_link_preview)
      |> assign(:reply_count, reply_count)
      |> assign(:reactions, reactions)
      |> assign(:formatted_reactions, formatted_reactions)
      |> assign(
        :show_body_content,
        Elektrine.Strings.present?(post.content) && (!assigns.clickable || is_nil(title))
      )
      |> assign(:unique_id, "lemmy-post-#{post.id}")

    ~H"""
    <article
      id={@unique_id}
      class={[
        "card panel-card timeline-post-card border border-base-300 rounded-lg overflow-visible transition-colors relative z-0",
        if(@clickable, do: "cursor-pointer")
      ]}
      data-post-id={@post.id}
      data-source={@source}
      phx-hook={if @clickable, do: "PostClick", else: nil}
      role="article"
      aria-label={"Post: #{@title || "Untitled"}"}
    >
      <%= if @clickable do %>
        <.link
          navigate={Elektrine.Paths.post_path(@post)}
          class="hidden"
          data-post-nav-link
          tabindex="-1"
          aria-hidden="true"
        >
          Open post
        </.link>
      <% end %>

      <div class="flex">
        <!-- Vote Column -->
        <div
          class="flex flex-col items-center self-start h-fit p-2 bg-base-200/50 gap-1 w-12 flex-shrink-0"
          role="group"
          aria-label="Voting"
        >
          <%= if @current_user do %>
            <button
              phx-click={if @is_liked, do: @on_unlike, else: @on_like}
              phx-value-post_id={@post.id}
              class={[
                "inline-flex h-7 w-7 items-center justify-center rounded-md border border-transparent p-1 transition-none sm:h-9 sm:w-9 sm:p-2 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
                if(@is_liked,
                  do:
                    if(@like_only_mode,
                      do: "bg-error/20 text-error hover:bg-error/30",
                      else: "bg-success/20 text-success hover:bg-success/30"
                    ),
                  else:
                    if(@like_only_mode,
                      do: "text-base-content/75 hover:bg-error/20 hover:text-error",
                      else: "text-base-content/75 hover:bg-success/20 hover:text-success"
                    )
                )
              ]}
              aria-label={
                if @like_only_mode,
                  do: if(@is_liked, do: "Unlike", else: "Like"),
                  else: if(@is_liked, do: "Remove upvote", else: "Upvote")
              }
              aria-pressed={@is_liked}
              type="button"
            >
              <.icon
                name={
                  if @like_only_mode,
                    do: if(@is_liked, do: "hero-heart-solid", else: "hero-heart"),
                    else: if(@is_liked, do: "hero-arrow-up-solid", else: "hero-arrow-up")
                }
                class="w-4 h-4 sm:w-5 sm:h-5 transition-none"
              />
            </button>
          <% else %>
            <div class="inline-flex h-7 w-7 items-center justify-center rounded-md border border-transparent p-1 opacity-50 cursor-not-allowed sm:h-9 sm:w-9 sm:p-2">
              <.icon
                name={if @like_only_mode, do: "hero-heart", else: "hero-arrow-up"}
                class="w-4 h-4 sm:w-5 sm:h-5"
              />
            </div>
          <% end %>
          <span
            class="text-sm sm:text-lg font-bold"
            aria-label={if @score_available, do: "Score: #{@score}", else: "Score: 0"}
          >
            <%= if @score_available do %>
              {@score}
            <% else %>
              0
            <% end %>
          </span>
          <%= if !@like_only_mode and @current_user do %>
            <button
              phx-click={if @is_downvoted, do: @on_undownvote, else: @on_downvote}
              phx-value-post_id={@post.id}
              class={[
                "inline-flex h-7 w-7 items-center justify-center rounded-md border border-transparent p-1 transition-none sm:h-9 sm:w-9 sm:p-2 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
                if(@is_downvoted,
                  do: "bg-error/20 text-error hover:bg-error/30",
                  else: "text-base-content/75 hover:bg-error/20 hover:text-error"
                )
              ]}
              aria-label={if @is_downvoted, do: "Remove downvote", else: "Downvote"}
              aria-pressed={@is_downvoted}
              type="button"
            >
              <.icon
                name={if @is_downvoted, do: "hero-arrow-down-solid", else: "hero-arrow-down"}
                class="w-4 h-4 sm:w-5 sm:h-5 transition-none"
              />
            </button>
          <% else %>
            <%= if !@like_only_mode do %>
              <div class="inline-flex h-7 w-7 items-center justify-center rounded-md border border-transparent p-1 opacity-50 cursor-not-allowed sm:h-9 sm:w-9 sm:p-2">
                <.icon name="hero-arrow-down" class="w-4 h-4 sm:w-5 sm:h-5" />
              </div>
            <% end %>
          <% end %>
        </div>
        
    <!-- Thumbnail for image posts or link icon for link submissions -->
        <%= if @has_thumbnail_image do %>
          <div class="w-20 h-20 flex-shrink-0 m-2">
            <%= cond do %>
              <% @has_image && @on_image_click -> %>
                <button
                  type="button"
                  class="image-zoom-trigger w-full h-full rounded overflow-hidden"
                  phx-click={@on_image_click}
                  phx-value-images={Jason.encode!(@image_urls)}
                  phx-value-index="0"
                  phx-value-post_id={@post.id}
                >
                  <img
                    src={@thumbnail_image_url}
                    alt=""
                    class="w-full h-full object-cover"
                    loading="lazy"
                  />
                </button>
              <% @external_link -> %>
                <a
                  href={@external_link}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="block w-full h-full"
                >
                  <img
                    src={@thumbnail_image_url}
                    alt=""
                    class="w-full h-full object-cover rounded hover:opacity-80 transition-opacity"
                    loading="lazy"
                  />
                </a>
              <% true -> %>
                <img
                  src={@thumbnail_image_url}
                  alt=""
                  class="w-full h-full object-cover rounded"
                  loading="lazy"
                />
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
        <div class="flex-1 p-2 min-w-0">
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
              <.link navigate={Elektrine.Paths.post_path(@post)} class="block">
                <h3 class="font-medium text-sm mb-1 line-clamp-2 hover:text-secondary">{@title}</h3>
              </.link>
            <% end %>
          <% end %>
          
    <!-- Community body: full content on detail pages, compact preview on list cards -->
          <%= if @show_body_content do %>
            <%= if @clickable && !@title do %>
              <div class="text-sm line-clamp-2 mb-1 break-words opacity-80">
                {raw(
                  PostUtilities.render_content_preview(
                    @post.content,
                    PostUtilities.get_instance_domain(@post)
                  )
                )}
              </div>
            <% else %>
              <div class="text-sm mb-2 break-words post-content opacity-90">
                {raw(render_post_content(@post))}
              </div>
            <% end %>
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
            <%= if @resolved_link_preview && !@has_image do %>
              <div class="text-xs text-primary truncate mb-1">
                <a
                  href={@resolved_link_preview.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="hover:underline flex items-center gap-1"
                >
                  <.icon name="hero-link" class="w-3 h-3 flex-shrink-0" />
                  <span class="truncate">{URI.parse(@resolved_link_preview.url).host}</span>
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
              >
                @{@post.remote_actor.username}
              </.link>
              <span>·</span>
            <% end %>
            <%= if @community_uri do %>
              <%= if @community_path do %>
                <.link navigate={@community_path} class="text-secondary hover:underline">
                  {@community_label}
                </.link>
              <% else %>
                <span class="text-secondary">{@community_label}</span>
              <% end %>
              <span>·</span>
            <% end %>
            <.local_time datetime={@post.inserted_at} format="relative" timezone={@timezone} />
            <span>·</span>
            <span>{@reply_count} comments</span>
            <span>·</span>
            <.link navigate={Elektrine.Paths.post_path(@post)} class="hover:text-primary">
              Open
            </.link>
            <%= if @post.activitypub_url do %>
              <a
                href={@post.activitypub_url}
                target="_blank"
                rel="noopener noreferrer"
                class="hover:text-primary ml-auto"
              >
                <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
              </a>
            <% end %>
          </div>
          
    <!-- Emoji Reactions -->
          <%= if @current_user || !Enum.empty?(@formatted_reactions) do %>
            <div class="flex items-center gap-1 mt-2 flex-wrap">
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
                    <span>{raw(render_custom_emojis(emoji))}</span>
                    <span class="font-medium">{count}</span>
                  </button>
                <% else %>
                  <span
                    class="px-1.5 py-0.5 rounded text-xs bg-base-200 border border-base-300 flex items-center gap-1 tooltip tooltip-top"
                    data-tip={tooltip}
                  >
                    <span>{raw(render_custom_emojis(emoji))}</span>
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
              <% reply_reaction = reply_reaction_surface(reply, @post_reactions_map)
              reply_avatar_url = PostUtilities.get_reply_avatar_url(reply)
              reply_content = PostUtilities.get_reply_content(reply)

              reply_preview =
                reply_content
                |> PostUtilities.render_content_preview(PostUtilities.get_instance_domain(reply))
                |> String.trim()

              reply_fallback =
                reply_content
                |> PostUtilities.plain_text_preview(200)
                |> String.trim() %>
              <div class="flex gap-2 text-sm">
                <div class="w-0.5 bg-base-300 flex-shrink-0"></div>
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-1 text-xs text-base-content/50 mb-0.5">
                    <%= if Elektrine.Strings.present?(reply_avatar_url) do %>
                      <img
                        src={reply_avatar_url}
                        alt=""
                        class="w-4 h-4 rounded-full object-cover flex-shrink-0"
                      />
                    <% else %>
                      <.placeholder_avatar size="2xs" class="w-4 h-4 flex-shrink-0" />
                    <% end %>
                    <span class="font-medium">
                      {PostUtilities.get_reply_author(reply)}
                    </span>
                    <%= if (reply_score = PostUtilities.get_reply_score(reply)) && reply_score > 0 do %>
                      <span class="text-secondary">+{reply_score}</span>
                    <% end %>
                  </div>
                  <div class="line-clamp-2 text-xs break-words">
                    <%= if reply_preview != "" do %>
                      {raw(reply_preview)}
                    <% else %>
                      <%= if reply_fallback != "" do %>
                        {reply_fallback}
                      <% else %>
                        <span class="italic text-base-content/60">Media-only comment</span>
                      <% end %>
                    <% end %>
                  </div>
                  <%= if reply_reaction.target_id do %>
                    <div class="mt-1.5">
                      <.post_reactions
                        post_id={reply_reaction.target_id}
                        value_name={reply_reaction.value_name}
                        actor_uri={reply_reaction.actor_uri}
                        reactions={reply_reaction.reactions}
                        current_user={@current_user}
                        size={:xs}
                      />
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
            <%= if @reply_count > length(@replies) do %>
              <.link
                navigate={Elektrine.Paths.post_path(@post)}
                class="text-xs text-primary hover:underline"
              >
                View all {@reply_count} comments
              </.link>
            <% end %>
            <%= if @post.federated && @post.activitypub_url do %>
              <a
                href={@post.activitypub_url}
                target="_blank"
                rel="noopener noreferrer"
                class="text-xs text-base-content/70 hover:text-primary inline-flex items-center gap-1"
              >
                <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                Open full conversation on origin
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

    {display_like_count, display_comment_count} =
      PostUtilities.get_display_counts(post, assigns.lemmy_counts, assigns.post_replies)

    # Compact cards should use the same title fallback chain as Lemmy cards.
    title = resolve_federated_title(post)

    # Get thumbnail if available
    image_urls = PostUtilities.filter_image_urls(post.media_urls || [])
    has_image = !Enum.empty?(image_urls)
    thumbnail = if has_image, do: thumbnail_url(hd(image_urls), 64), else: nil

    assigns =
      assigns
      |> assign(:is_reply, is_reply)
      |> assign(:is_gallery_post, is_gallery_post)
      |> assign(:display_like_count, display_like_count)
      |> assign(:display_comment_count, display_comment_count)
      |> assign(:title, title)
      |> assign(:has_image, has_image)
      |> assign(:thumbnail, thumbnail)

    ~H"""
    <div
      id={"compact-post-#{@post.id}"}
      class={[
        "flex items-start gap-3 p-3 border-b border-base-200 hover:bg-base-100 transition-colors",
        if(@clickable, do: "cursor-pointer"),
        if(@is_reply, do: "border-l-2 border-l-error/40", else: "")
      ]}
      data-post-id={@post.id}
      data-source={@source}
      phx-hook={if @clickable, do: "PostClick", else: nil}
    >
      <%= if @clickable do %>
        <.link
          navigate={Elektrine.Paths.post_path(@post)}
          class="hidden"
          data-post-nav-link
          tabindex="-1"
          aria-hidden="true"
        >
          Open post
        </.link>
      <% end %>
      
    <!-- Thumbnail -->
      <%= if @has_image do %>
        <div class="w-16 h-16 flex-shrink-0 rounded overflow-hidden">
          <img src={@thumbnail} alt="" class="w-full h-full object-cover" loading="lazy" />
        </div>
      <% end %>

      <div class="flex-1 min-w-0">
        <!-- Title or content preview -->
        <%= if @title do %>
          <.link navigate={Elektrine.Paths.post_path(@post)} class="block">
            <h3 class="font-medium text-sm line-clamp-2 mb-1">{@title}</h3>
          </.link>
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
          <span>·</span>
          <.link navigate={Elektrine.Paths.post_path(@post)} class="hover:text-primary">
            Open
          </.link>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions - delegate to PostUtilities where possible
  defp extract_community_name(uri), do: PostUtilities.extract_community_name_simple(uri)

  defp community_path(%{conversation: %{type: "community", name: name}}, _community_uri)
       when is_binary(name),
       do: "/communities/#{name}"

  defp community_path(
         %{conversation: %{remote_group_actor: %{username: username, domain: domain}}},
         _community_uri
       )
       when is_binary(username) and is_binary(domain),
       do: "/remote/!#{username}@#{domain}"

  defp community_path(_post, community_uri) when is_binary(community_uri) do
    case URI.parse(community_uri) do
      %URI{host: host, path: "/c/" <> community_name}
      when is_binary(host) and community_name != "" ->
        "/remote/!#{community_name}@#{host}"

      _ ->
        nil
    end
  end

  defp community_path(_, _), do: nil

  defp video_url?(url), do: PostUtilities.video_url?(url)

  defp audio_url?(url), do: PostUtilities.audio_url?(url)

  defp quoted_post_url(%{federated: true, activitypub_id: activitypub_id} = post)
       when is_binary(activitypub_id) do
    if Elektrine.Strings.present?(activitypub_id) do
      Elektrine.Paths.post_path(post)
    else
      "#"
    end
  end

  defp quoted_post_url(%{
         id: message_id,
         reply_to_id: reply_to_id,
         conversation: %{type: "timeline"}
       })
       when not is_nil(reply_to_id),
       do: Elektrine.Paths.anchored_post_path(reply_to_id, message_id)

  defp quoted_post_url(%{id: message_id, conversation: %{type: "timeline"}}),
    do: Elektrine.Paths.post_path(message_id)

  defp quoted_post_url(%{
         id: message_id,
         reply_to_id: reply_to_id,
         conversation: %{type: "community", name: name}
       })
       when not is_nil(reply_to_id),
       do: Elektrine.Paths.discussion_message_path(name, reply_to_id, message_id)

  defp quoted_post_url(%{id: message_id, conversation: %{type: "community", name: name}}),
    do: Elektrine.Paths.discussion_post_path(name, message_id)

  defp quoted_post_url(%{id: message_id, conversation: %{type: "chat", hash: hash}})
       when is_binary(hash) do
    if Elektrine.Strings.present?(hash) do
      Elektrine.Paths.chat_message_path(hash, message_id)
    else
      Elektrine.Paths.chat_message_path(message_id, message_id)
    end
  end

  defp quoted_post_url(%{id: message_id, conversation: %{type: "chat", id: conv_id}}),
    do: Elektrine.Paths.chat_message_path(conv_id, message_id)

  defp quoted_post_url(%{id: message_id}), do: Elektrine.Paths.post_path(message_id)
  defp quoted_post_url(_), do: "#"

  defp normalize_post_title(title) when is_binary(title) do
    title = String.trim(title)
    Elektrine.Strings.present(title)
  end

  defp normalize_post_title(_), do: nil

  defp resolve_federated_title(post) when is_map(post) do
    metadata = Map.get(post, :media_metadata) || %{}

    [
      Map.get(post, :title),
      Map.get(post, "title"),
      Map.get(metadata, "name"),
      Map.get(metadata, :name),
      Map.get(metadata, "title"),
      Map.get(metadata, :title)
    ]
    |> Enum.find_value(&normalize_post_title/1)
  end

  defp resolve_federated_title(_), do: nil

  defp normalize_reply_author_info(author, in_reply_to_url) when is_binary(author) do
    author = String.trim(author)
    inferred_label = infer_reply_label_from_url(in_reply_to_url)

    cond do
      not Elektrine.Strings.present?(author) ->
        %{name: "a post", type: :unknown}

      String.starts_with?(author, "@") ->
        %{name: author, type: :federated}

      String.starts_with?(author, "someone on ") ->
        %{
          name:
            inferred_label || "a post on " <> String.replace_prefix(author, "someone on ", ""),
          type: :external
        }

      String.starts_with?(author, "a post on ") ->
        %{name: inferred_label || author, type: :external}

      String.starts_with?(author, "post ") && String.contains?(author, " on ") ->
        %{name: author, type: :external}

      String.starts_with?(author, "http://") || String.starts_with?(author, "https://") ->
        %{name: infer_reply_label_from_url(author) || "a post", type: :external}

      true ->
        %{name: author, type: :federated}
    end
  end

  defp normalize_reply_author_info(_, _), do: %{name: "a post", type: :unknown}

  defp infer_reply_label_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %{host: host, path: path} when is_binary(host) and is_binary(path) ->
        case infer_username_from_reply_path(path) do
          username when is_binary(username) ->
            "@#{username}@#{host}"

          _ ->
            case infer_post_id_from_reply_path(path) do
              post_id when is_binary(post_id) -> "post #{post_id} on #{host}"
              _ -> "a post on #{host}"
            end
        end

      %{host: host} when is_binary(host) and host != "" ->
        "a post on #{host}"

      _ ->
        nil
    end
  end

  defp infer_reply_label_from_url(_), do: nil

  defp infer_username_from_reply_path(path) when is_binary(path) do
    case reply_path_segments(path) do
      ["users", username | _] ->
        trim_reply_identifier(username)

      ["u", username | _] ->
        trim_reply_identifier(username)

      [segment | _] ->
        if String.starts_with?(segment, "@"), do: trim_reply_identifier(segment), else: nil

      _ ->
        nil
    end
  end

  defp infer_username_from_reply_path(_), do: nil

  defp infer_post_id_from_reply_path(path) when is_binary(path) do
    candidate =
      case reply_path_segments(path) do
        ["users", _username, "statuses", post_id | _] -> post_id
        ["notice", post_id | _] -> post_id
        ["objects", post_id | _] -> post_id
        ["posts", post_id | _] -> post_id
        ["post", post_id | _] -> post_id
        ["comments", post_id | _] -> post_id
        ["comment", post_id | _] -> post_id
        [first, post_id | _] -> if String.starts_with?(first, "@"), do: post_id, else: nil
        _ -> nil
      end

    trim_reply_identifier(candidate)
  end

  defp infer_post_id_from_reply_path(_), do: nil

  defp reply_path_segments(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp trim_reply_identifier(value) when is_binary(value) do
    value
    |> URI.decode()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.split(["?", "#"], parts: 2)
    |> List.first()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_reply_identifier(_), do: nil

  defp preview_display_text(text, max_len) when is_binary(text) and is_integer(max_len) do
    text
    |> decode_preview_entities()
    |> String.slice(0, max_len)
  end

  defp preview_display_text(_, _), do: nil

  defp decode_preview_entities(text), do: decode_preview_entities(text, 3)

  defp decode_preview_entities(text, remaining) when is_binary(text) and remaining > 0 do
    decoded = HtmlEntities.decode(text)
    if decoded == text, do: decoded, else: decode_preview_entities(decoded, remaining - 1)
  end

  defp decode_preview_entities(text, _), do: text

  defp link_preview_success?(preview) do
    social_link_preview?(preview) and Map.get(preview, :status) == "success"
  end

  defp social_link_preview?(%{__struct__: :"Elixir.Elektrine.Social.LinkPreview"}), do: true
  defp social_link_preview?(_), do: false
end
