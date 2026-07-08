defmodule ElektrineSocialWeb.Components.Social.TimelinePost do
  @moduledoc """
  Unified timeline post component for rendering posts across timeline, hashtag, and other feed views.
  Supports local posts, federated posts, boosts, replies, polls, cross-posts, and all media types.

  ## Layout Variants

  The component supports different layout variants via the `:layout` attribute:

  - `:dense` (default) - Stream layout with tighter spacing
  - `:timeline` - Standard social media post layout with full content
  - `:lemmy` - Reddit/Lemmy style with vote column on left, thumbnail, and compact meta
  - `:compact` - Minimal layout for dense feeds

  ## Usage

      <.timeline_post post={post} current_user={@current_user} layout={:dense} />
      <.timeline_post post={post} current_user={@current_user} layout={:lemmy} />
  """
  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]
  import ElektrineWeb.CoreComponents
  import ElektrineWeb.HtmlHelpers
  import ElektrineSocialWeb.Components.Social.EmbeddedPost, only: [embedded_post: 1]
  import ElektrineSocialWeb.Components.Social.PostReactions, only: [post_reactions: 1]
  import ElektrineSocialWeb.Components.Social.TimelinePostMedia
  import ElektrineSocialWeb.Components.Social.TimelinePostFooter, only: [post_footer: 1]
  import ElektrineSocialWeb.Components.Social.ContentJourney, only: [content_journey: 1]
  import Elektrine.Components.User.Avatar
  import Elektrine.Components.User.UsernameEffects
  import ElektrineSocialWeb.Components.User.HoverCard

  alias ElektrineSocialWeb.Components.Social.PostUtilities
  alias ElektrineSocialWeb.Components.Social.TimelinePostAncestors
  alias ElektrineSocialWeb.Components.Social.TimelinePostCard
  alias ElektrineSocialWeb.Components.Social.TimelinePostCompact
  alias ElektrineWeb.Platform.Integrations

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
  * `:layout` - Layout variant: :dense (default), :timeline, :lemmy, or :compact
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
  attr :layout, :atom, default: :dense
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
  attr :counts_loading, :boolean, default: false

  def timeline_post(assigns) do
    # Dispatch based on layout variant
    case assigns.layout do
      :dense -> render_dense_timeline_layout(assigns)
      :lemmy -> render_lemmy_layout(assigns)
      :compact -> TimelinePostCompact.render_compact_layout(assigns)
      _ -> render_timeline_layout(assigns)
    end
  end

  # Standard timeline layout
  defp render_timeline_layout(assigns) do
    if pure_boost_post?(assigns.post) do
      render_boost_wrapper_layout(assigns)
    else
      render_standard_timeline_layout(assigns)
    end
  end

  defp render_boost_wrapper_layout(assigns, nested_layout \\ :timeline) do
    assigns =
      assigns
      |> assign(:boosted_post, assigns.post.shared_message)
      |> assign(:booster, Map.get(assigns.post, :sender))
      |> assign(:boosted_layout, nested_layout)

    ~H"""
    <div id={"#{@id_prefix}-entry-#{@post.id}"} class="space-y-2">
      <div class="flex min-w-0 items-center gap-2 px-4 text-sm leading-none text-base-content/65">
        <.icon name="hero-arrow-path" class="h-4 w-4 shrink-0 text-success" />
        <%= if @booster do %>
          <.user_hover_card
            id={"#{@id_prefix}-boost-hover-#{@post.id}"}
            user={@booster}
            current_user={@current_user}
            user_follows={@user_follows}
          >
            <.link
              navigate={"/#{@booster.handle || @booster.username}"}
              class="inline-flex min-w-0 shrink items-center gap-1.5 font-medium leading-none text-success hover:underline"
            >
              <.user_avatar user={@booster} size="xs" />
              <span class="truncate leading-none">
                <.username_with_effects user={@booster} display_name={true} verified_size="xs" />
              </span>
            </.link>
          </.user_hover_card>
          <span class="shrink-0 leading-none">boosted</span>
        <% else %>
          <span class="shrink-0 font-medium leading-none text-success">Someone</span>
          <span class="shrink-0 leading-none">boosted</span>
        <% end %>
      </div>

      <.timeline_post
        post={@boosted_post}
        layout={@boosted_layout}
        current_user={@current_user}
        timezone={@timezone}
        time_format={@time_format}
        user_likes={@user_likes}
        user_boosts={@user_boosts}
        user_downvotes={@user_downvotes}
        user_saves={@user_saves}
        user_follows={@user_follows}
        pending_follows={@pending_follows}
        remote_follow_overrides={@remote_follow_overrides}
        user_statuses={@user_statuses}
        lemmy_counts={@lemmy_counts}
        post_replies={@post_replies}
        post_interactions={@post_interactions}
        post_reactions_map={@post_reactions_map}
        reactions={reactions_for_keys(@post_reactions_map, interaction_keys(@boosted_post))}
        id_prefix={"#{@id_prefix}-boosted-#{@post.id}"}
        show_follow_button={@show_follow_button}
        show_admin_actions={@show_admin_actions}
        show_post_dropdown={@show_post_dropdown}
        show_view_button={@show_view_button}
        on_navigate_profile={@on_navigate_profile}
        on_image_click={@on_image_click}
        on_like={@on_like}
        on_unlike={@on_unlike}
        on_comment={@on_comment}
        clickable={@clickable}
        source={@source}
        resolve_reply_refs={@resolve_reply_refs}
        show_ancestor_actions={@show_ancestor_actions}
        show_quote_button={@show_quote_button}
        show_save_button={@show_save_button}
        show_thread_context={false}
        interaction_mode={@interaction_mode}
        remote_poll_vote={@remote_poll_vote}
        action_post_id={@boosted_post.id}
        action_value_name="message_id"
        save_action_post_id={@boosted_post.id}
        save_action_value_name="message_id"
        counts_loading={@counts_loading}
      />
    </div>
    """
  end

  defp render_dense_timeline_layout(assigns) do
    if pure_boost_post?(assigns.post) do
      render_boost_wrapper_layout(assigns, :dense)
    else
      render_dense_standard_timeline_layout(assigns)
    end
  end

  defp render_dense_standard_timeline_layout(assigns) do
    post = assigns.post
    is_reply = PostUtilities.reply?(post)
    is_gallery_post = PostUtilities.gallery_post?(post)

    reply_ancestors =
      if is_reply do
        TimelinePostAncestors.resolve_for_post(
          post,
          assigns.source,
          assigns.resolve_reply_refs
        )
      else
        []
      end

    {base_like_count, display_comment_count} =
      PostUtilities.get_display_counts(post, assigns.lemmy_counts, assigns.post_replies)

    post_state = current_post_interaction_state(assigns.post_interactions, post)
    display_like_count = max(base_like_count + Map.get(post_state, :like_delta, 0), 0)

    display_boost_count =
      max(PostUtilities.display_share_count(post) + Map.get(post_state, :boost_delta, 0), 0)

    is_liked = Map.get(post_state, :liked, current_post_flag(assigns.user_likes, post))
    is_boosted = Map.get(post_state, :boosted, current_post_flag(assigns.user_boosts, post))

    is_saved =
      if is_nil(assigns.saved_override),
        do: current_post_flag(assigns.user_saves, post),
        else: assigns.saved_override

    card_post_path = TimelinePostCard.card_post_path(post, assigns.source)

    assigns =
      assigns
      |> assign_new(:remote_poll_vote, fn -> nil end)
      |> assign(:is_reply, is_reply)
      |> assign(:is_gallery_post, is_gallery_post)
      |> assign(:direct_reply_target, List.last(reply_ancestors))
      |> assign(:display_like_count, display_like_count)
      |> assign(:display_boost_count, display_boost_count)
      |> assign(:display_comment_count, display_comment_count)
      |> assign(:is_liked, is_liked)
      |> assign(:is_boosted, is_boosted)
      |> assign(:is_saved, is_saved)
      |> assign(:card_post_path, card_post_path)
      |> assign(:card_post_external?, TimelinePostCard.external_url?(card_post_path))

    ~H"""
    <article
      id={"#{@id_prefix}-entry-#{@post.id}"}
      class="relative"
    >
      <div
        id={"#{@id_prefix}-card-#{@post.id}"}
        class={[
          "timeline-post-card timeline-post-card--dense relative z-0 max-w-full overflow-visible rounded-lg border border-base-300/70 px-3 py-3 transition-colors sm:px-4",
          if(@clickable, do: "cursor-pointer")
        ]}
        data-post-id={@post.id}
        data-source={@source}
        phx-hook={if @clickable, do: "PostClick", else: nil}
      >
        <%= if @clickable do %>
          <%= if @card_post_external? do %>
            <.link
              href={@card_post_path}
              class="hidden"
              data-post-nav-link
              tabindex="-1"
              aria-hidden="true"
            >
              Open post
            </.link>
          <% else %>
            <.link
              navigate={@card_post_path}
              class="hidden"
              data-post-nav-link
              tabindex="-1"
              aria-hidden="true"
            >
              Open post
            </.link>
          <% end %>
        <% end %>

        <div class="flex min-w-0 items-start gap-3">
          <.dense_author_avatar
            post={@post}
            user_statuses={@user_statuses}
            on_navigate_profile={@on_navigate_profile}
          />

          <div class="min-w-0 flex-1">
            <div class="relative min-w-0 pr-9">
              <.dense_author_meta
                post={@post}
                current_user={@current_user}
                timezone={@timezone}
                time_format={@time_format}
                user_statuses={@user_statuses}
                user_follows={@user_follows}
                pending_follows={@pending_follows}
                remote_follow_overrides={@remote_follow_overrides}
                id_prefix={@id_prefix}
                on_navigate_profile={@on_navigate_profile}
              />

              <%= if @current_user && @show_post_dropdown do %>
                <div class="absolute right-0 top-[-0.35rem] z-[320]">
                  <.post_dropdown
                    post={@post}
                    current_user={@current_user}
                    show_admin_actions={@show_admin_actions}
                    id_prefix={@id_prefix}
                  />
                </div>
              <% end %>
            </div>

            <.boost_indicator post={@post} />
            <.dense_reply_target :if={@is_reply} target={@direct_reply_target} />

            <div class="timeline-post-dense-content mt-1 min-w-0">
              <.post_content
                post={@post}
                current_user={@current_user}
                is_gallery_post={@is_gallery_post}
                on_image_click={@on_image_click}
                remote_poll_vote={@remote_poll_vote}
                id_prefix={@id_prefix}
                source={@source}
              />
            </div>

            <div class="timeline-post-dense-footer mt-1">
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
                show_view_button={false}
                id_prefix={@id_prefix}
                is_liked={@is_liked}
                is_boosted={@is_boosted}
                is_saved={@is_saved}
                on_comment={@on_comment}
                show_quote_button={@show_quote_button}
                show_save_button={@show_save_button}
                reactions={@reactions}
                on_react={@on_react}
                action_post_id={@action_post_id}
                action_value_name={@action_value_name}
                save_action_post_id={@save_action_post_id}
                save_action_value_name={@save_action_value_name}
                counts_loading={@counts_loading}
              />
            </div>

            <div :if={@reactions != []} class="mt-1">
              <.post_reactions
                post_id={@action_post_id || @post.id}
                value_name={@action_value_name}
                reactions={@reactions}
                current_user={@current_user}
                on_react={@on_react}
                size={:xs}
                show_picker={false}
              />
            </div>
          </div>
        </div>
      </div>
    </article>
    """
  end

  defp render_standard_timeline_layout(assigns) do
    post = assigns.post

    # Determine if this is a reply
    is_reply = PostUtilities.reply?(post)

    # Determine if this is a gallery post
    is_gallery_post = PostUtilities.gallery_post?(post)

    # Resolve ancestor context (root -> parent) only for replies.
    reply_ancestors =
      if is_reply do
        TimelinePostAncestors.resolve_for_post(
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

    display_like_count = max(base_like_count + Map.get(post_state, :like_delta, 0), 0)

    display_boost_count =
      max(PostUtilities.display_share_count(post) + Map.get(post_state, :boost_delta, 0), 0)

    is_liked = Map.get(post_state, :liked, current_post_flag(assigns.user_likes, post))
    is_boosted = Map.get(post_state, :boosted, current_post_flag(assigns.user_boosts, post))

    is_saved =
      if is_nil(assigns.saved_override),
        do: current_post_flag(assigns.user_saves, post),
        else: assigns.saved_override

    card_post_path = TimelinePostCard.card_post_path(post, assigns.source)

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
      |> assign(:card_post_path, card_post_path)
      |> assign(:card_post_external?, TimelinePostCard.external_url?(card_post_path))

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
            <%= if @card_post_external? do %>
              <.link
                href={@card_post_path}
                class="hidden"
                data-post-nav-link
                tabindex="-1"
                aria-hidden="true"
              >
                Open post
              </.link>
            <% else %>
              <.link
                navigate={@card_post_path}
                class="hidden"
                data-post-nav-link
                tabindex="-1"
                aria-hidden="true"
              >
                Open post
              </.link>
            <% end %>
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
              user_follows={@user_follows}
              pending_follows={@pending_follows}
              remote_follow_overrides={@remote_follow_overrides}
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
              id_prefix={@id_prefix}
              source={@source}
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
              reactions={@reactions}
              on_react={@on_react}
              action_post_id={@action_post_id}
              action_value_name={@action_value_name}
              save_action_post_id={@save_action_post_id}
              save_action_value_name={@save_action_value_name}
              counts_loading={@counts_loading}
            />
            
    <!-- Emoji Reactions -->
            <div class="mt-3 pt-3 border-t border-base-200">
              <.post_reactions
                post_id={@action_post_id || @post.id}
                value_name={@action_value_name}
                reactions={@reactions}
                current_user={@current_user}
                on_react={@on_react}
                size={:xs}
                show_picker={false}
              />
            </div>
          </div>

          <%= if @current_user && @show_post_dropdown do %>
            <div class="absolute right-4 top-4 z-[320]">
              <.post_dropdown
                post={@post}
                current_user={@current_user}
                show_admin_actions={@show_admin_actions}
                id_prefix={@id_prefix}
              />
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp pure_boost_post?(post) do
    shared_message = Map.get(post, :shared_message)

    not is_nil(Map.get(post, :shared_message_id)) &&
      is_map(shared_message) &&
      Ecto.assoc_loaded?(shared_message) &&
      !Elektrine.Strings.present?(Map.get(post, :content))
  end

  attr :post, :map, required: true
  attr :user_statuses, :map, default: %{}
  attr :on_navigate_profile, :string, default: "navigate_to_profile"

  defp dense_author_avatar(assigns) do
    ~H"""
    <div class="h-10 w-10 flex-shrink-0 overflow-visible">
      <%= if @post.federated && Ecto.assoc_loaded?(@post.remote_actor) && @post.remote_actor do %>
        <.link
          navigate={"/remote/#{@post.remote_actor.username}@#{@post.remote_actor.domain}"}
          class="block h-10 w-10 rounded-full"
        >
          <%= if avatar_url = PostUtilities.safe_image_url(@post.remote_actor.avatar_url) do %>
            <img
              src={avatar_url}
              alt={@post.remote_actor.username}
              class="h-10 w-10 rounded-full object-cover"
            />
          <% else %>
            <.placeholder_avatar size="md" class="h-10 w-10" />
          <% end %>
        </.link>
      <% else %>
        <%= if @post.sender do %>
          <button
            phx-click={@on_navigate_profile}
            phx-value-handle={@post.sender.handle || @post.sender.username}
            phx-value-user_id={@post.sender.id}
            class="h-10 w-10"
            type="button"
          >
            <.user_avatar user={@post.sender} size="sm" />
          </button>
        <% else %>
          <.placeholder_avatar size="md" class="h-10 w-10" />
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "12h"
  attr :user_statuses, :map, default: %{}
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :remote_follow_overrides, :map, default: %{}
  attr :id_prefix, :string, default: "post"
  attr :on_navigate_profile, :string, default: "navigate_to_profile"

  defp dense_author_meta(assigns) do
    ~H"""
    <%= if @post.federated && Ecto.assoc_loaded?(@post.remote_actor) && @post.remote_actor do %>
      <.dense_remote_author_meta
        post={@post}
        current_user={@current_user}
        timezone={@timezone}
        time_format={@time_format}
        user_follows={@user_follows}
        pending_follows={@pending_follows}
        remote_follow_overrides={@remote_follow_overrides}
        id_prefix={@id_prefix}
      />
    <% else %>
      <.dense_local_author_meta
        :if={@post.sender}
        post={@post}
        current_user={@current_user}
        timezone={@timezone}
        time_format={@time_format}
        user_statuses={@user_statuses}
        user_follows={@user_follows}
        id_prefix={@id_prefix}
        on_navigate_profile={@on_navigate_profile}
      />
    <% end %>
    """
  end

  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "12h"
  attr :user_statuses, :map, default: %{}
  attr :user_follows, :map, default: %{}
  attr :id_prefix, :string, default: "post"
  attr :on_navigate_profile, :string, default: "navigate_to_profile"

  defp dense_local_author_meta(assigns) do
    ~H"""
    <.user_hover_card
      id={"#{@id_prefix}-author-hover-#{@post.id}"}
      user={@post.sender}
      user_statuses={@user_statuses}
      user_follows={@user_follows}
      current_user={@current_user}
      class="!block min-w-0"
      trigger_class="inline-flex max-w-full min-w-0 items-center gap-1.5 align-baseline"
    >
      <button
        phx-click={@on_navigate_profile}
        phx-value-handle={@post.sender.handle || @post.sender.username}
        phx-value-user_id={@post.sender.id}
        class="min-w-0 truncate text-left text-[15px] font-semibold leading-5 hover:text-error"
        type="button"
      >
        <.username_with_effects user={@post.sender} display_name={true} verified_size="xs" />
      </button>
      <span class="min-w-0 truncate text-sm leading-5 text-base-content/55">
        @{@post.sender.handle || @post.sender.username}@{Elektrine.Domains.default_user_handle_domain()}
      </span>
      <span class="flex-shrink-0 text-sm leading-5 text-base-content/45">·</span>
      <span class="flex-shrink-0 text-sm leading-5 text-base-content/55">
        <.local_time
          datetime={@post.inserted_at}
          format="relative"
          timezone={@timezone}
          time_format={@time_format}
        />
      </span>
      <%= if @post.edited_at do %>
        <span
          class="inline-flex flex-shrink-0 text-base-content/45"
          title={"Edited #{Integrations.social_time_ago(@post.edited_at)}"}
        >
          <.icon name="hero-pencil" class="h-2.5 w-2.5" />
        </span>
      <% end %>
      <.dense_visibility_icon visibility={@post.visibility} />
    </.user_hover_card>
    """
  end

  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "12h"
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :remote_follow_overrides, :map, default: %{}
  attr :id_prefix, :string, default: "post"

  defp dense_remote_author_meta(assigns) do
    community_uri = PostUtilities.community_actor_uri(assigns.post)

    assigns =
      assigns
      |> assign(:community_uri, community_uri)
      |> assign(:community_path, community_path(assigns.post, community_uri))

    ~H"""
    <.user_hover_card
      id={"#{@id_prefix}-remote-author-hover-#{@post.id}"}
      remote_actor={@post.remote_actor}
      current_user={@current_user}
      user_follows={@user_follows}
      pending_follows={@pending_follows}
      remote_follow_overrides={@remote_follow_overrides}
      class="!block min-w-0"
      trigger_class="inline-flex max-w-full min-w-0 items-center gap-1.5 align-baseline"
    >
      <.link
        navigate={"/remote/#{@post.remote_actor.username}@#{@post.remote_actor.domain}"}
        class="min-w-0 truncate text-[15px] font-semibold leading-5 hover:text-primary"
      >
        {raw(
          render_display_name_with_emojis(
            @post.remote_actor.display_name || @post.remote_actor.username,
            @post.remote_actor.domain
          )
        )}
      </.link>
      <span class="min-w-0 truncate text-sm leading-5 text-base-content/55">
        @{@post.remote_actor.username}@{@post.remote_actor.domain}
      </span>
      <%= if @community_uri do %>
        <span class="hidden flex-shrink-0 text-sm leading-5 text-base-content/45 sm:inline">
          in
        </span>
        <%= if @community_path do %>
          <.link
            navigate={@community_path}
            class="hidden min-w-0 truncate text-sm leading-5 text-base-content/60 hover:text-primary sm:inline"
          >
            {extract_community_name(@community_uri)}
          </.link>
        <% else %>
          <span class="hidden min-w-0 truncate text-sm leading-5 text-base-content/60 sm:inline">
            {extract_community_name(@community_uri)}
          </span>
        <% end %>
      <% end %>
      <span class="flex-shrink-0 text-sm leading-5 text-base-content/45">·</span>
      <span class="flex-shrink-0 text-sm leading-5 text-base-content/55">
        <.local_time
          datetime={@post.inserted_at}
          format="relative"
          timezone={@timezone}
          time_format={@time_format}
        />
      </span>
      <span class="inline-flex flex-shrink-0 text-base-content/45" title="Federated post">
        <.icon name="hero-globe-alt" class="h-2.5 w-2.5" />
      </span>
      <%= if @post.edited_at do %>
        <span
          class="inline-flex flex-shrink-0 text-base-content/45"
          title={"Edited #{Integrations.social_time_ago(@post.edited_at)}"}
        >
          <.icon name="hero-pencil" class="h-2.5 w-2.5" />
        </span>
      <% end %>
    </.user_hover_card>
    """
  end

  attr :target, :map, default: nil

  defp dense_reply_target(assigns) do
    ~H"""
    <%= if is_map(@target) do %>
      <% clickable = TimelinePostAncestors.clickable?(@target)
      subtitle = TimelinePostAncestors.author_subtitle(@target) %>
      <div class="mb-1 mt-0.5 text-xs leading-5 text-base-content/55">
        <span>Replying to</span>
        <%= if clickable do %>
          <button
            type="button"
            class={[
              "font-medium hover:underline",
              TimelinePostAncestors.author_class(@target.author_info.type)
            ]}
            {TimelinePostAncestors.click_attrs(@target)}
          >
            {@target.author_info.name}
          </button>
        <% else %>
          <span class={[
            "font-medium",
            TimelinePostAncestors.author_class(@target.author_info.type)
          ]}>
            {@target.author_info.name}
          </span>
        <% end %>
        <span :if={subtitle} class="text-base-content/45">{subtitle}</span>
      </div>
    <% end %>
    """
  end

  attr :visibility, :string, default: "public"

  defp dense_visibility_icon(assigns) do
    ~H"""
    <%= case @visibility do %>
      <% "public" -> %>
        <span class="inline-flex flex-shrink-0 text-base-content/45" title="Public">
          <.icon name="hero-globe-alt" class="h-3 w-3" />
        </span>
      <% "followers" -> %>
        <span class="inline-flex flex-shrink-0 text-info/70" title="Followers only">
          <.icon name="hero-user-group" class="h-3 w-3" />
        </span>
      <% "friends" -> %>
        <span class="inline-flex flex-shrink-0 text-success/70" title="Friends only">
          <.icon name="hero-heart" class="h-3 w-3" />
        </span>
      <% "private" -> %>
        <span class="inline-flex flex-shrink-0 text-warning/70" title="Private">
          <.icon name="hero-lock-closed" class="h-3 w-3" />
        </span>
      <% _ -> %>
    <% end %>
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
            <%= if booster_avatar_url = PostUtilities.safe_image_url(booster["avatar_url"]) do %>
              <img
                src={booster_avatar_url}
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
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :remote_follow_overrides, :map, default: %{}
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
          user_follows={@user_follows}
          pending_follows={@pending_follows}
          remote_follow_overrides={@remote_follow_overrides}
          current_user={@current_user}
          id_prefix={@id_prefix}
        />
      <% else %>
        <!-- Local post -->
        <%= if @post.sender do %>
          <.local_author_header
            post={@post}
            timezone={@timezone}
            time_format={@time_format}
            user_statuses={@user_statuses}
            user_follows={@user_follows}
            current_user={@current_user}
            id_prefix={@id_prefix}
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
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :remote_follow_overrides, :map, default: %{}
  attr :current_user, :map, default: nil
  attr :id_prefix, :string, default: "post"

  defp remote_author_header(assigns) do
    community_uri = PostUtilities.community_actor_uri(assigns.post)

    assigns =
      assigns
      |> assign(:community_uri, community_uri)
      |> assign(:community_path, community_path(assigns.post, community_uri))

    ~H"""
    <.user_hover_card
      id={"#{@id_prefix}-remote-header-hover-#{@post.id}"}
      remote_actor={@post.remote_actor}
      current_user={@current_user}
      user_follows={@user_follows}
      pending_follows={@pending_follows}
      remote_follow_overrides={@remote_follow_overrides}
      class="!flex min-w-0 flex-1 items-center gap-3"
      trigger_class="inline-flex max-w-full min-w-0 items-center gap-3"
    >
      <.link
        navigate={"/remote/#{@post.remote_actor.username}@#{@post.remote_actor.domain}"}
        class="w-10 h-10 rounded-full block flex-shrink-0"
      >
        <%= if avatar_url = PostUtilities.safe_image_url(@post.remote_actor.avatar_url) do %>
          <img
            src={avatar_url}
            alt={@post.remote_actor.username}
            class="w-10 h-10 rounded-full object-cover shadow-lg"
          />
        <% else %>
          <.placeholder_avatar size="md" class="shadow-lg" />
        <% end %>
      </.link>
      <div class="flex-1 min-w-0 flex flex-col justify-center">
        <div class="flex items-center gap-1.5">
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
    </.user_hover_card>
    """
  end

  # Local author header
  attr :post, :map, required: true
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "12h"
  attr :user_statuses, :map, default: %{}
  attr :user_follows, :map, default: %{}
  attr :current_user, :map, default: nil
  attr :id_prefix, :string, default: "post"
  attr :on_navigate_profile, :string, default: "navigate_to_profile"

  defp local_author_header(assigns) do
    ~H"""
    <.user_hover_card
      id={"#{@id_prefix}-local-header-hover-#{@post.id}"}
      user={@post.sender}
      user_statuses={@user_statuses}
      user_follows={@user_follows}
      current_user={@current_user}
      class="!flex min-w-0 flex-1 items-center gap-3"
      trigger_class="inline-flex max-w-full min-w-0 items-center gap-3"
    >
      <button
        phx-click={@on_navigate_profile}
        phx-value-handle={@post.sender.handle || @post.sender.username}
        phx-value-user_id={@post.sender.id}
        class="w-10 h-10 flex-shrink-0"
        type="button"
      >
        <.user_avatar user={@post.sender} size="sm" user_statuses={@user_statuses} />
      </button>
      <div class="flex-1 min-w-0 flex flex-col justify-center">
        <button
          phx-click={@on_navigate_profile}
          phx-value-handle={@post.sender.handle || @post.sender.username}
          phx-value-user_id={@post.sender.id}
          class="font-medium hover:text-error transition-colors text-left truncate"
          type="button"
        >
          <.username_with_effects user={@post.sender} display_name={true} verified_size="sm" />
        </button>
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
    </.user_hover_card>
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
  attr :id_prefix, :string, default: "post"

  defp post_dropdown(assigns) do
    ~H"""
    <div
      class="dropdown timeline-post-dropdown dropdown-end flex-shrink-0"
      id={"#{@id_prefix}-post-dropdown-#{@post.id}"}
      data-portal-dropdown-root
      data-portal-align="end"
      data-portal-placement="bottom"
    >
      <button
        type="button"
        class="btn btn-ghost btn-xs btn-square h-7 w-7 min-h-0 sm:h-8 sm:w-8"
        aria-haspopup="menu"
        aria-expanded="false"
        data-portal-dropdown-trigger
      >
        <.icon name="hero-ellipsis-vertical" class="w-4 h-4" />
      </button>
      <ul
        tabindex="-1"
        class="dropdown-content timeline-post-dropdown-menu menu p-2 rounded-box w-52"
        role="menu"
        data-portal-dropdown-menu
      >
        <!-- View/Open Actions -->
        <%= if @post.federated && PostUtilities.safe_external_href(@post.activitypub_url) do %>
          <li>
            <a
              href={PostUtilities.safe_external_href(@post.activitypub_url)}
              target="_blank"
              rel="noopener noreferrer"
            >
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
        <%= if is_struct(@post, Elektrine.Social.Message) do %>
          <%= if Elektrine.Social.ThreadMutes.muted?(@current_user.id, @post) do %>
            <li>
              <button phx-click="unmute_thread" phx-value-message_id={@post.id} type="button">
                <.icon name="hero-bell" class="w-4 h-4" /> Unmute Conversation
              </button>
            </li>
          <% else %>
            <li>
              <button phx-click="mute_thread" phx-value-message_id={@post.id} type="button">
                <.icon name="hero-bell-slash" class="w-4 h-4" /> Mute Conversation
              </button>
            </li>
          <% end %>
        <% end %>
        
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
          <.mute_user_items post={@post} current_user={@current_user} />
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

  # Mute user menu entries for the post dropdown.
  attr :post, :map, required: true
  attr :current_user, :map, required: true

  def mute_user_items(assigns) do
    ~H"""
    <%= cond do %>
      <% is_nil(@current_user) -> %>
      <% local_mute_target(@post, @current_user) -> %>
        <% sender = @post.sender %>
        <%= if Elektrine.Accounts.user_muted?(@current_user.id, sender.id) do %>
          <li>
            <button phx-click="unmute_user" phx-value-user_id={sender.id} type="button">
              <.icon name="hero-speaker-wave" class="w-4 h-4" />
              Unmute @{sender.handle || sender.username}
            </button>
          </li>
        <% else %>
          <li>
            <details>
              <summary>
                <.icon name="hero-speaker-x-mark" class="w-4 h-4" />
                Mute @{sender.handle || sender.username}
              </summary>
              <ul>
                <%= for {duration, label} <- mute_duration_options() do %>
                  <li>
                    <button
                      phx-click="mute_user"
                      phx-value-user_id={sender.id}
                      phx-value-duration={duration}
                      type="button"
                    >
                      {label}
                    </button>
                  </li>
                <% end %>
              </ul>
            </details>
          </li>
        <% end %>
      <% remote_mute_target(@post) -> %>
        <% actor = @post.remote_actor %>
        <%= if Elektrine.Accounts.remote_actor_muted?(@current_user.id, actor.id) do %>
          <li>
            <button phx-click="unmute_remote_actor" phx-value-actor_id={actor.id} type="button">
              <.icon name="hero-speaker-wave" class="w-4 h-4" />
              Unmute @{actor.username}@{actor.domain}
            </button>
          </li>
        <% else %>
          <li>
            <button phx-click="mute_remote_actor" phx-value-actor_id={actor.id} type="button">
              <.icon name="hero-speaker-x-mark" class="w-4 h-4" />
              Mute @{actor.username}@{actor.domain}
            </button>
          </li>
        <% end %>
      <% true -> %>
    <% end %>
    """
  end

  def mute_duration_options do
    [
      {"1800", "For 30 minutes"},
      {"3600", "For 1 hour"},
      {"86400", "For 1 day"},
      {"604800", "For 1 week"},
      {"", "Until I unmute"}
    ]
  end

  defp local_mute_target(post, current_user) do
    sender = Map.get(post, :sender)

    is_map(sender) && !match?(%Ecto.Association.NotLoaded{}, sender) &&
      is_integer(Map.get(sender, :id)) && sender.id != current_user.id
  end

  defp remote_mute_target(post) do
    actor = Map.get(post, :remote_actor)

    is_map(actor) && !match?(%Ecto.Association.NotLoaded{}, actor) &&
      is_integer(Map.get(actor, :id))
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
      <%= if @ancestor.remote_actor do %>
        <%= if avatar_url = PostUtilities.safe_image_url(@ancestor.remote_actor.avatar_url) do %>
          <img
            src={avatar_url}
            alt=""
            class="w-6 h-6 rounded-full object-cover flex-shrink-0"
          />
        <% else %>
          <div class="w-6 h-6 rounded-full bg-base-300 flex items-center justify-center flex-shrink-0">
            <.icon name="hero-user" class="w-3.5 h-3.5 opacity-60" />
          </div>
        <% end %>
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
      <% clickable = TimelinePostAncestors.clickable?(@target)
      subtitle = TimelinePostAncestors.author_subtitle(@target) %>
      <div class="timeline-inline-reply-target mb-3">
        <div class="mb-1 text-[11px] font-medium uppercase tracking-[0.18em] text-base-content/45">
          In reply to
        </div>

        <%= if clickable do %>
          <button
            type="button"
            class="thread-context-card timeline-inline-reply-target__card w-full text-left"
            {TimelinePostAncestors.click_attrs(@target)}
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
          <span class={[
            "truncate font-medium",
            TimelinePostAncestors.author_class(@target.author_info.type)
          ]}>
            {@target.author_info.name}
          </span>
          <%= if @subtitle do %>
            <span class="truncate text-xs text-base-content/55">{@subtitle}</span>
          <% end %>
          <%= if TimelinePostAncestors.clickable?(@target) do %>
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

  # Post content component
  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :is_gallery_post, :boolean, default: false
  attr :on_image_click, :string, default: "open_image_modal"
  attr :remote_poll_vote, :map, default: nil
  attr :id_prefix, :string, default: "post"
  attr :source, :string, default: "timeline"

  defp post_content(assigns) do
    title = TimelinePostCard.resolve_federated_title(assigns.post)
    post_path = TimelinePostCard.card_post_path(assigns.post, assigns.source)

    assigns =
      assigns
      |> assign_new(:remote_poll_vote, fn -> nil end)
      |> assign(:title, title)
      |> assign(:post_path, post_path)
      |> assign(:post_path_external?, TimelinePostCard.external_url?(post_path))

    ~H"""
    <!-- Title -->
    <%= if @title do %>
      <.link
        href={if @post_path_external?, do: @post_path, else: nil}
        navigate={if @post_path_external?, do: nil, else: @post_path}
        class="block hover:text-primary transition-colors"
      >
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
        <span class="text-xs opacity-70">Hover or focus to reveal</span>
        <span class="badge badge-sm badge-warning ml-auto">Sensitive</span>
      </div>
    <% end %>

    <!-- Main Content -->
    <div
      class={"mb-3 min-w-0 #{if Elektrine.Strings.present?(@post.content_warning), do: "blur-sm hover:blur-none focus-within:blur-none transition-all", else: ""}"}
      tabindex={if Elektrine.Strings.present?(@post.content_warning), do: "0", else: nil}
    >
      <!-- Quoted post content -->
      <%= if @post.quoted_message_id && Ecto.assoc_loaded?(@post.quoted_message) && @post.quoted_message do %>
        <%= if Elektrine.Strings.present?(@post.content) do %>
          <div class="break-words mb-3 post-content line-clamp-4 overflow-hidden">
            {raw(render_post_content(@post))}
          </div>
        <% end %>
        <div
          id={"#{@id_prefix}-quoted-post-#{@post.id}-#{@post.quoted_message_id}"}
          class="border border-base-300 rounded-lg p-3 bg-base-200/30 hover:bg-base-200/50 transition-colors"
        >
          <div class="flex items-center gap-2 mb-2">
            <.icon name="hero-chat-bubble-bottom-center-text" class="w-4 h-4 text-info flex-shrink-0" />
            <span class="text-xs font-medium text-info">Quoting</span>
          </div>
          <div class="flex items-center gap-2 mb-2">
            <%= if @post.quoted_message.sender do %>
              <.user_hover_card
                id={"#{@id_prefix}-quoted-avatar-hover-#{@post.id}-#{@post.quoted_message_id}"}
                user={@post.quoted_message.sender}
                user_follows={@user_follows}
              >
                <.link
                  navigate={"/#{@post.quoted_message.sender.handle || @post.quoted_message.sender.username}"}
                  class="w-6 h-6"
                >
                  <.user_avatar user={@post.quoted_message.sender} size="xs" />
                </.link>
              </.user_hover_card>
              <.user_hover_card
                id={"#{@id_prefix}-quoted-name-hover-#{@post.id}-#{@post.quoted_message_id}"}
                user={@post.quoted_message.sender}
                user_follows={@user_follows}
              >
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
                  <%= if avatar_url = PostUtilities.safe_image_url(@post.quoted_message.remote_actor.avatar_url) do %>
                    <img
                      src={avatar_url}
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
                <%= if full_url = attachment_url_for_render(media_url, @post.quoted_message) do %>
                  <img src={full_url} alt="" class="w-16 h-16 rounded object-cover" />
                <% end %>
              <% end %>
              <%= if length(@post.quoted_message.media_urls) > 2 do %>
                <div class="w-16 h-16 rounded bg-base-300 flex items-center justify-center text-xs opacity-60">
                  +{length(@post.quoted_message.media_urls) - 2}
                </div>
              <% end %>
            </div>
          <% end %>
          <% quoted_link_preview = PostUtilities.visible_link_preview(@post.quoted_message) %>
          <%= if quoted_link_preview && PostUtilities.safe_external_href(quoted_link_preview.url) do %>
            <div class="mt-2 border border-base-300 rounded overflow-hidden">
              <a
                href={PostUtilities.safe_external_href(quoted_link_preview.url)}
                target="_blank"
                rel="noopener noreferrer"
                class="flex items-center gap-2 p-2 hover:bg-base-200/50 transition-colors"
              >
                <%= if image_url = PostUtilities.safe_image_url(quoted_link_preview.image_url) do %>
                  <img
                    id={"#{@id_prefix}-quoted-preview-image-#{@post.id || :erlang.phash2(quoted_link_preview.image_url)}"}
                    src={image_url}
                    alt=""
                    class="w-12 h-12 rounded object-cover flex-shrink-0"
                    phx-hook="ImageFallback"
                  />
                <% end %>
                <div class="min-w-0 flex-1">
                  <%= if quoted_link_preview.title do %>
                    <div class="text-xs font-medium truncate">
                      {String.slice(quoted_link_preview.title, 0, 60)}
                    </div>
                  <% end %>
                  <div class="text-xs opacity-60 truncate">
                    {safe_preview_host(quoted_link_preview)}
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
        id_prefix={@id_prefix}
        source={@source}
      />
      
    <!-- Media attachments -->
      <.media_attachments
        post={@post}
        is_gallery_post={@is_gallery_post}
        on_image_click={@on_image_click}
        id_prefix={@id_prefix}
        source={@source}
      />
      
    <!-- Link Preview -->
      <.link_preview post={@post} id_prefix={@id_prefix} />
    </div>
    """
  end

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
    [post.id, Integer.to_string(post.id), post.activitypub_id, post.activitypub_url]
    |> Enum.reject(&is_nil/1)
  end

  # Lemmy/Reddit style layout with vote column
  defp render_lemmy_layout(assigns) do
    post = assigns.post
    post_id = post.activitypub_id || to_string(post.id)

    # Get interaction state
    post_state =
      [post.id, Integer.to_string(post.id), post.activitypub_id, post.activitypub_url]
      |> Enum.reject(&is_nil/1)
      |> Enum.find_value(%{liked: false, downvoted: false, like_delta: 0}, fn key ->
        Map.get(assigns.post_interactions, key)
      end)

    like_only_mode = assigns.interaction_mode == :like_only

    # Prefer the explicit community vote state used by the remote post surface,
    # while still supporting portal's existing user_likes/user_downvotes maps.
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
    cached_primary_count = PostUtilities.display_primary_count(post, lemmy_counts)

    base_count =
      cond do
        like_only_mode && cached_primary_count != 0 ->
          cached_primary_count

        like_only_mode && is_integer(post.like_count) && post.like_count != 0 ->
          post.like_count

        like_only_mode && is_integer(post.score) && post.score != 0 ->
          post.score

        like_only_mode && is_map(lemmy_counts) && is_integer(Map.get(lemmy_counts, :score)) &&
            Map.get(lemmy_counts, :score) != 0 ->
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

        is_map(lemmy_counts) && is_integer(Map.get(lemmy_counts, :score)) &&
            Map.get(lemmy_counts, :score) != 0 ->
          Map.get(lemmy_counts, :score)

        !is_vote_post && cached_primary_count != 0 ->
          cached_primary_count

        !is_vote_post && is_integer(post.like_count) && post.like_count != 0 ->
          post.like_count

        !is_vote_post && is_integer(post.score) && post.score != 0 ->
          post.score

        true ->
          cached_primary_count
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

    score = if is_integer(base_count), do: base_count + score_delta, else: 0

    # Prefer attached media, but fall back to link preview images for link submissions.
    image_urls = PostUtilities.filter_image_urls(post.media_urls || [])
    has_image = !Enum.empty?(image_urls)
    image_url = if has_image, do: thumbnail_url(hd(image_urls), 96), else: nil

    external_link = PostUtilities.detect_external_link(post)
    resolved_link_preview = PostUtilities.visible_link_preview(post)

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
    title = TimelinePostCard.resolve_federated_title(post)
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
      [post.id, Integer.to_string(post.id), post.activitypub_id, post.activitypub_url]
      |> Enum.reject(&is_nil/1)

    reactions =
      case reactions_for_keys(assigns.post_reactions_map, reaction_keys) do
        [] -> assigns.reactions
        live_reactions -> live_reactions
      end

    # Format reactions
    current_user_id = if assigns.current_user, do: assigns.current_user.id, else: nil
    formatted_reactions = PostUtilities.format_reactions(reactions, current_user_id)
    card_post_path = TimelinePostCard.card_post_path(post, assigns.source)

    assigns =
      assigns
      |> assign(:post_id, post_id)
      |> assign(:is_liked, is_liked)
      |> assign(:is_downvoted, is_downvoted)
      |> assign(:score, score)
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
      |> assign(:card_post_path, card_post_path)
      |> assign(:card_post_external?, TimelinePostCard.external_url?(card_post_path))
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
        <%= if @card_post_external? do %>
          <.link
            href={@card_post_path}
            class="hidden"
            data-post-nav-link
            tabindex="-1"
            aria-hidden="true"
          >
            Open post
          </.link>
        <% else %>
          <.link
            navigate={@card_post_path}
            class="hidden"
            data-post-nav-link
            tabindex="-1"
            aria-hidden="true"
          >
            Open post
          </.link>
        <% end %>
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
                      else: "bg-secondary/20 text-secondary hover:bg-secondary/30"
                    ),
                  else:
                    if(@like_only_mode,
                      do: "text-base-content/50 hover:bg-error/20 hover:text-error",
                      else: "text-base-content/50 hover:bg-secondary/20 hover:text-secondary"
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
            class={[
              cond do
                @is_liked and !@like_only_mode -> "text-secondary"
                @is_downvoted -> "text-error"
                true -> ""
              end
            ]}
            aria-label={"Score: #{@score}"}
          >
            <span
              id={"#{@unique_id}-score-count"}
              class="text-sm sm:text-lg font-bold"
              phx-hook="AnimatedCount"
              phx-update="ignore"
              data-count={@score}
              aria-hidden="true"
            >
              {@score}
            </span>
          </span>
          <%= if !@like_only_mode and @current_user do %>
            <button
              phx-click={if @is_downvoted, do: @on_undownvote, else: @on_downvote}
              phx-value-post_id={@post.id}
              class={[
                "inline-flex h-7 w-7 items-center justify-center rounded-md border border-transparent p-1 transition-none sm:h-9 sm:w-9 sm:p-2 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
                if(@is_downvoted,
                  do: "bg-error/20 text-error hover:bg-error/30",
                  else: "text-base-content/50 hover:bg-error/20 hover:text-error"
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
              <.link navigate={@card_post_path} class="block">
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
            <% preview_href =
              if @resolved_link_preview && !@has_image,
                do: PostUtilities.safe_external_href(@resolved_link_preview.url) %>
            <%= if preview_href do %>
              <div class="text-xs text-primary truncate mb-1">
                <a
                  href={preview_href}
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
            <span>
              <span
                id={"#{@unique_id}-comments-count"}
                phx-hook="AnimatedCount"
                phx-update="ignore"
                data-count={@reply_count}
              >
                {@reply_count}
              </span>
              comments
            </span>
            <span>·</span>
            <.link navigate={@card_post_path} class="hover:text-primary">
              Open
            </.link>
            <%= if PostUtilities.safe_external_href(@post.activitypub_url) do %>
              <a
                href={PostUtilities.safe_external_href(@post.activitypub_url)}
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
            <div class="mt-3 flex flex-wrap items-center gap-x-2 gap-y-1.5 rounded-md bg-base-200/45 p-2">
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
                      "px-1.5 py-0.5 rounded text-xs border flex items-center gap-1 transition-colors",
                      if(user_reacted,
                        do: "bg-secondary/20 border-secondary text-secondary",
                        else: "bg-base-200 border-base-300 hover:bg-base-300"
                      )
                    ]}
                    data-tip={tooltip}
                    data-portal-tooltip
                  >
                    <span>{raw(render_reaction_emoji(emoji))}</span>
                    <span class="font-medium">{count}</span>
                  </button>
                <% else %>
                  <span
                    class="px-1.5 py-0.5 rounded text-xs bg-base-200 border border-base-300 flex items-center gap-1"
                    data-tip={tooltip}
                    data-portal-tooltip
                  >
                    <span>{raw(render_reaction_emoji(emoji))}</span>
                    <span class="font-medium">{count}</span>
                  </span>
                <% end %>
              <% end %>
              
    <!-- Quick reaction buttons -->
              <%= if @current_user do %>
                <div class="ml-0.5 flex items-center gap-1 border-l border-base-300/70 pl-2">
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
                        "btn btn-ghost btn-square btn-xs text-sm",
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
            <%= if @post.federated && PostUtilities.safe_external_href(@post.activitypub_url) do %>
              <a
                href={PostUtilities.safe_external_href(@post.activitypub_url)}
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

  # Helper functions - delegate to PostUtilities where possible
  defp extract_community_name(uri), do: PostUtilities.extract_community_name_simple(uri)

  defp community_path(%{conversation: %{type: "community", name: name}}, _community_uri)
       when is_binary(name),
       do: Elektrine.Paths.community_path(name)

  defp community_path(
         %{conversation: %{remote_group_actor: %{username: username, domain: domain}}},
         _community_uri
       )
       when is_binary(username) and is_binary(domain),
       do: Elektrine.Paths.remote_community_path(username, domain)

  defp community_path(_post, community_uri) when is_binary(community_uri) do
    case URI.parse(community_uri) do
      %URI{host: host, path: "/c/" <> community_name}
      when is_binary(host) and community_name != "" ->
        Elektrine.Paths.remote_community_path(community_name, host)

      _ ->
        nil
    end
  end

  defp community_path(_, _), do: nil

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

  defp render_reaction_emoji(emoji) when is_binary(emoji) do
    emoji
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
    |> render_custom_emojis()
  end

  defp render_reaction_emoji(_), do: ""
end
