defmodule ElektrineSocialWeb.RemotePostLive.ThreadedCommentComponents do
  @moduledoc false

  use ElektrineSocialWeb, :html

  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.Paths
  alias ElektrineWeb.UrlHelpers

  alias ElektrineSocialWeb.RemotePostLive.{
    SurfaceHelpers,
    Threading
  }

  alias ElektrineWeb.Live.PostInteractions

  import ElektrineSocialWeb.Components.Social.PostActions, only: [post_actions: 1]
  import ElektrineSocialWeb.Components.Social.PostReactions, only: [post_reactions: 1]
  import ElektrineSocialWeb.RemotePostLive.ReplyAuthorComponents, only: [reply_author_summary: 1]

  import ElektrineWeb.HtmlHelpers,
    only: [render_remote_post_content: 3, safe_external_href: 1, safe_external_image_url: 1]

  def render_threaded_comments(assigns, comments) do
    # Determine if this is a Lemmy post based on presence of community_actor
    is_lemmy_post = assigns[:community_actor] != nil

    thread_reply_actors =
      assigns[:thread_reply_actors] || Threading.build_thread_reply_actor_cache(comments)

    assigns =
      assigns
      |> assign(:comments, comments)
      |> assign(:is_lemmy_post, is_lemmy_post)
      |> assign(:post_reactions, assigns[:post_reactions] || %{})
      |> assign(:user_follows, assigns[:user_follows] || %{})
      |> assign(:pending_follows, assigns[:pending_follows] || %{})
      |> assign(:remote_follow_overrides, assigns[:remote_follow_overrides] || %{})
      |> assign(:reply_content_domain, assigns[:reply_content_domain])
      |> assign(:thread_reply_actors, thread_reply_actors)

    ~H"""
    <%= for node <- @comments do %>
      <% reply_view = reply_view_model(assigns, node) %>
      <% depth = reply_view.depth %>
      <% children = reply_view.children %>
      <% is_reply_liked = reply_view.liked %>
      <% is_reply_boosted = reply_view.boosted %>
      <% user_vote = reply_view.vote %>
      <% reply_like_count = reply_view.like_count %>
      <% reply_boost_count = reply_view.boost_count %>
      <% reply_child_count = reply_view.child_count %>
      <% reply_reaction = reply_view.reaction %>
      <% reply_local_message_id = reply_view.local_message_id %>
      <% reply_submitted_url = reply_view.submitted_url %>
      <% reply_youtube_id = reply_view.youtube_id %>
      <% reply_link_preview = reply_view.link_preview %>
      <% reply_click = reply_view.click %>
      <% is_local_reply = reply_view.local? %>
      <% local_user = reply_view.local_user %>
      <% reply_actor = reply_view.actor %>
      <% reply_avatar_url = reply_view.avatar_url %>
      <% reply_profile_path = reply_view.profile_path %>
      <% reply_display_name = reply_view.display_name %>
      <% reply_acct_label = reply_view.acct_label %>
      <% tree_depth = reply_view.tree_depth %>
      <div
        id={reply_view.dom_id}
        class={[
          "timeline-thread-tree-node",
          if(depth == 0, do: "timeline-thread-reply-row"),
          if(depth > 0 and depth <= 4, do: "timeline-thread-tree-node--nested")
        ]}
        style={if depth > 0, do: "--thread-depth: #{tree_depth};", else: nil}
      >
        <%= if depth == 0 do %>
          <span class="timeline-thread-reply-node" aria-hidden="true"></span>
          <span class="timeline-thread-reply-elbow" aria-hidden="true"></span>
        <% end %>
        <%= if @is_lemmy_post do %>
          <!-- Lemmy-style comment (Reddit-style with vote column) -->
          <div class="flex gap-2 mb-2 min-w-0">
            <!-- Vote Column -->
            <div class="flex flex-col items-center gap-0.5 flex-shrink-0 pt-1">
              <%= if @current_user do %>
                <button
                  phx-click="vote_comment"
                  phx-value-comment_id={reply_view.card_post_id}
                  phx-value-activitypub_id={reply_view.activitypub_id}
                  phx-value-type="up"
                  class={[
                    "vote-up-button inline-flex h-6 w-6 items-center justify-center rounded-md border border-transparent p-1 transition-all duration-150 phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
                    if(user_vote == "up",
                      do:
                        "bg-secondary/20 text-secondary hover:bg-secondary/30 phx-click-loading:bg-transparent phx-click-loading:text-base-content/70",
                      else:
                        "text-base-content/50 hover:bg-secondary/20 hover:text-secondary phx-click-loading:bg-secondary/20 phx-click-loading:text-secondary"
                    )
                  ]}
                  aria-label={if user_vote == "up", do: "Remove upvote", else: "Upvote"}
                  aria-pressed={user_vote == "up"}
                  type="button"
                >
                  <span class="inline-flex phx-click-loading:hidden">
                    <.icon
                      name={if user_vote == "up", do: "hero-arrow-up-solid", else: "hero-arrow-up"}
                      class="w-3 h-3 sm:w-4 sm:h-4"
                    />
                  </span>
                  <span class="hidden phx-click-loading:inline-flex" aria-hidden="true">
                    <.icon
                      name={if user_vote == "up", do: "hero-arrow-up", else: "hero-arrow-up-solid"}
                      class="w-3 h-3 sm:w-4 sm:h-4"
                    />
                  </span>
                </button>
              <% else %>
                <div class="inline-flex h-6 w-6 items-center justify-center rounded-md border border-transparent p-1 opacity-50 cursor-not-allowed">
                  <.icon name="hero-arrow-up" class="w-3 h-3 sm:w-4 sm:h-4 transition-none" />
                </div>
              <% end %>
              <span
                class={[
                  "vote-score text-xs font-bold",
                  cond do
                    user_vote == "up" -> "text-secondary"
                    user_vote == "down" -> "text-error"
                    true -> ""
                  end
                ]}
                aria-label={"Score: #{reply_like_count}"}
              >
                <span
                  id={"#{reply_view.card_dom_id}-vote-count"}
                  class="vote-score-current"
                  phx-hook="AnimatedCount"
                  phx-update="ignore"
                  data-count={reply_like_count}
                >
                  {reply_like_count}
                </span>
                <span class="vote-score-pending hidden" aria-hidden="true">
                  {reply_like_count +
                    if(user_vote == "up", do: -1, else: if(user_vote == "down", do: 2, else: 1))}
                </span>
              </span>
              <%= if @current_user do %>
                <button
                  phx-click="vote_comment"
                  phx-value-comment_id={reply_view.card_post_id}
                  phx-value-activitypub_id={reply_view.activitypub_id}
                  phx-value-type="down"
                  class={[
                    "inline-flex h-6 w-6 items-center justify-center rounded-md border border-transparent p-1 transition-none phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
                    if(user_vote == "down",
                      do: "bg-error/20 text-error hover:bg-error/30",
                      else: "text-base-content/50 hover:bg-error/20 hover:text-error"
                    )
                  ]}
                  aria-label={if user_vote == "down", do: "Remove downvote", else: "Downvote"}
                  aria-pressed={user_vote == "down"}
                  type="button"
                >
                  <.icon
                    name={
                      if user_vote == "down", do: "hero-arrow-down-solid", else: "hero-arrow-down"
                    }
                    class="w-3 h-3 sm:w-4 sm:h-4 transition-none"
                  />
                </button>
              <% else %>
                <div class="inline-flex h-6 w-6 items-center justify-center rounded-md border border-transparent p-1 opacity-50 cursor-not-allowed">
                  <.icon name="hero-arrow-down" class="w-3 h-3 sm:w-4 sm:h-4 transition-none" />
                </div>
              <% end %>
            </div>
            
    <!-- Comment Content -->
            <div
              id={reply_view.card_dom_id}
              class={[
                "timeline-thread-comment-card timeline-post-card timeline-post-card--dense relative flex-1 min-w-0 rounded-lg border border-base-300/70 px-3 py-2 transition-colors duration-150",
                reply_click && "cursor-pointer hover:bg-base-200/35"
              ]}
              data-post-id={reply_view.card_post_id}
              data-source="remote_post_reply"
              data-track-dwell="false"
              phx-hook={reply_click && "PostClick"}
            >
              <%= if reply_click do %>
                <.link
                  navigate={Paths.post_path(reply_click.id || reply_click.post_id)}
                  class="hidden"
                  data-post-nav-link
                  tabindex="-1"
                  aria-hidden="true"
                >
                  Open reply
                </.link>
                <.link
                  navigate={Paths.post_path(reply_click.id || reply_click.post_id)}
                  class="pointer-events-none absolute inset-0 z-0 rounded-lg"
                  aria-label="Open reply"
                >
                  <span class="sr-only">Open reply</span>
                </.link>
              <% end %>
              <!-- Comment Header -->
              <div class="relative z-10 pointer-events-none flex flex-wrap items-center gap-x-3 gap-y-1 text-xs mb-1 min-w-0">
                <.reply_author_summary
                  layout={:inline}
                  local_user={if(is_local_reply, do: local_user)}
                  reply_actor={reply_actor}
                  avatar_url={reply_avatar_url}
                  profile_path={reply_profile_path}
                  display_name={reply_display_name}
                  acct_label={reply_acct_label}
                  published_label={reply_view.published_label}
                  current_user={@current_user}
                  user_follows={@user_follows}
                  pending_follows={@pending_follows}
                  remote_follow_overrides={@remote_follow_overrides}
                />
              </div>
              
    <!-- Comment Text -->
              <%= if reply_view.content_html do %>
                <div class={[
                  "relative z-10 pointer-events-none text-sm leading-relaxed mb-1.5 post-content rounded-md transition-colors [&_a]:pointer-events-auto [&_a]:relative [&_a]:z-20",
                  reply_click && "hover:bg-base-200/80"
                ]}>
                  {raw(reply_view.content_html)}
                </div>
              <% end %>

              <%= if is_binary(reply_submitted_url) do %>
                <div class="relative z-20 pointer-events-auto mt-2 mb-3 space-y-2">
                  <%= if reply_youtube_id do %>
                    <div class="rounded-lg overflow-hidden border border-base-300 bg-base-200/70">
                      <div class="aspect-video bg-base-200">
                        <iframe
                          src={"https://www.youtube.com/embed/#{reply_youtube_id}"}
                          title="YouTube video"
                          frameborder="0"
                          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                          allowfullscreen
                          class="w-full h-full"
                        >
                        </iframe>
                      </div>
                    </div>
                  <% else %>
                    <% safe_reply_preview_url =
                      if match?(%Elektrine.Social.LinkPreview{}, reply_link_preview),
                        do: safe_external_href(reply_submitted_url) %>
                    <%= if safe_reply_preview_url do %>
                      <a
                        href={safe_reply_preview_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="block rounded-lg border border-base-300 bg-base-100/90 p-3 hover:border-base-content/20 transition-colors"
                      >
                        <%= if preview_image_url = safe_external_image_url(reply_link_preview.image_url) do %>
                          <div class="mb-3 aspect-video rounded-md overflow-hidden bg-base-200">
                            <img
                              src={preview_image_url}
                              alt={reply_link_preview.title || safe_reply_preview_url}
                              class="w-full h-full object-cover"
                              loading="lazy"
                            />
                          </div>
                        <% end %>
                        <div class="space-y-1.5">
                          <div class="text-sm font-medium leading-snug">
                            {reply_link_preview.title || reply_link_preview.url}
                          </div>
                          <%= if Elektrine.Strings.present?(reply_link_preview.description) do %>
                            <div class="text-xs text-base-content/70 line-clamp-3">
                              {reply_link_preview.description}
                            </div>
                          <% end %>
                          <div class="text-[11px] text-base-content/50 truncate">
                            {safe_reply_preview_url}
                          </div>
                        </div>
                      </a>
                    <% end %>
                  <% end %>
                </div>
              <% end %>
              
    <!-- Reply Action -->
              <%= if @current_user do %>
                <div class="relative z-20 pointer-events-auto">
                  <button
                    phx-click="toggle_comment_reply"
                    phx-value-comment_id={reply_view.activitypub_id}
                    class={[
                      "text-xs transition-colors",
                      if(reply_view.replying?,
                        do: "text-secondary font-medium",
                        else: "text-base-content/50 hover:text-secondary"
                      )
                    ]}
                    type="button"
                  >
                    <%= if reply_child_count > 0 do %>
                      <span
                        id={"#{reply_view.card_dom_id}-inline-reply-count"}
                        phx-hook="AnimatedCount"
                        phx-update="ignore"
                        data-count={reply_child_count}
                      >
                        {reply_child_count}
                      </span>
                      replies
                    <% else %>
                      Reply
                    <% end %>
                  </button>
                </div>
              <% else %>
                <%= if reply_child_count > 0 do %>
                  <span class="text-xs text-base-content/40">
                    <span
                      id={"#{reply_view.card_dom_id}-inline-readonly-reply-count"}
                      phx-hook="AnimatedCount"
                      phx-update="ignore"
                      data-count={reply_child_count}
                    >
                      {reply_child_count}
                    </span>
                    replies
                  </span>
                <% end %>
              <% end %>

              <%= if reply_reaction.target_id do %>
                <div class="relative z-20 pointer-events-auto mt-2">
                  <.post_reactions
                    post_id={reply_reaction.target_id}
                    value_name={reply_reaction.value_name}
                    reactions={reply_reaction.reactions}
                    current_user={@current_user}
                    size={:xs}
                    portal={false}
                  />
                </div>
              <% end %>
              
    <!-- Inline Reply Form -->
              <%= if @current_user && reply_view.replying? do %>
                <form phx-submit="submit_comment_reply" class="relative z-20 pointer-events-auto mt-2">
                  <textarea
                    name="content"
                    phx-keyup="update_comment_reply_content"
                    value={@comment_reply_content}
                    placeholder="Write a reply..."
                    class="textarea textarea-bordered textarea-sm w-full min-h-[60px] text-sm"
                    rows="2"
                  ></textarea>
                  <div class="flex justify-end gap-2 mt-1.5">
                    <button
                      type="button"
                      phx-click="toggle_comment_reply"
                      phx-value-comment_id={reply_view.activitypub_id}
                      class="btn btn-ghost btn-xs"
                    >
                      Cancel
                    </button>
                    <button type="submit" class="btn btn-secondary btn-xs">
                      Reply
                    </button>
                  </div>
                </form>
              <% end %>
            </div>
          </div>
        <% else %>
          <!-- Timeline-style comment (traditional social media with hearts) -->
          <div
            id={reply_view.card_dom_id}
            class={[
              "timeline-thread-tree-card timeline-thread-comment-card timeline-post-card timeline-post-card--dense relative rounded-lg p-3 mb-2 border border-base-300/70 transition-colors duration-150",
              reply_click && "cursor-pointer hover:bg-base-200/35"
            ]}
            data-post-id={reply_view.card_post_id}
            data-source="remote_post_reply"
            data-track-dwell="false"
            phx-hook={reply_click && "PostClick"}
          >
            <%= if reply_click do %>
              <.link
                navigate={Paths.post_path(reply_click.id || reply_click.post_id)}
                class="hidden"
                data-post-nav-link
                tabindex="-1"
                aria-hidden="true"
              >
                Open reply
              </.link>
              <.link
                navigate={Paths.post_path(reply_click.id || reply_click.post_id)}
                class="pointer-events-none absolute inset-0 z-0 rounded-lg"
                aria-label="Open reply"
              >
                <span class="sr-only">Open reply</span>
              </.link>
            <% end %>
            <!-- Comment Header -->
            <div class="relative z-10 pointer-events-none flex items-start gap-3 mb-2 min-w-0">
              <.reply_author_summary
                layout={:stacked}
                local_user={if(is_local_reply, do: local_user)}
                reply_actor={reply_actor}
                avatar_url={reply_avatar_url}
                profile_path={reply_profile_path}
                display_name={reply_display_name}
                acct_label={reply_acct_label}
                published_label={reply_view.published_label}
                current_user={@current_user}
                user_follows={@user_follows}
                pending_follows={@pending_follows}
                remote_follow_overrides={@remote_follow_overrides}
              />
            </div>

            <%= if depth > 0 do %>
              <div class={[
                "relative z-10 pointer-events-none text-xs text-base-content/60 mb-2 flex items-center gap-1 rounded-md transition-colors",
                reply_click && "hover:bg-base-200/80"
              ]}>
                <.icon name="hero-arrow-uturn-left" class="w-3 h-3" /> Thread reply
              </div>
            <% end %>
            
    <!-- Comment Content -->
            <%= if reply_view.content_html do %>
              <div class={[
                "relative z-10 pointer-events-none text-sm leading-relaxed mb-2 post-content rounded-md transition-colors [&_a]:pointer-events-auto [&_a]:relative [&_a]:z-20",
                reply_click && "hover:bg-base-200/80"
              ]}>
                {raw(reply_view.content_html)}
              </div>
            <% end %>

            <%= if is_binary(reply_submitted_url) do %>
              <div class="relative z-20 pointer-events-auto mt-2 mb-3 space-y-2">
                <%= if reply_youtube_id do %>
                  <div class="rounded-lg overflow-hidden border border-base-300 bg-base-200/70">
                    <div class="aspect-video bg-base-200">
                      <iframe
                        src={"https://www.youtube.com/embed/#{reply_youtube_id}"}
                        title="YouTube video"
                        frameborder="0"
                        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
                        allowfullscreen
                        class="w-full h-full"
                      >
                      </iframe>
                    </div>
                  </div>
                <% else %>
                  <% safe_reply_preview_url =
                    if match?(%Elektrine.Social.LinkPreview{}, reply_link_preview),
                      do: safe_external_href(reply_submitted_url) %>
                  <%= if safe_reply_preview_url do %>
                    <a
                      href={safe_reply_preview_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="block rounded-lg border border-base-300 bg-base-100/90 p-3 hover:border-base-content/20 transition-colors"
                    >
                      <%= if preview_image_url = safe_external_image_url(reply_link_preview.image_url) do %>
                        <div class="mb-3 aspect-video rounded-md overflow-hidden bg-base-200">
                          <img
                            src={preview_image_url}
                            alt={reply_link_preview.title || safe_reply_preview_url}
                            class="w-full h-full object-cover"
                            loading="lazy"
                          />
                        </div>
                      <% end %>
                      <div class="space-y-1.5">
                        <div class="text-sm font-medium leading-snug">
                          {reply_link_preview.title || reply_link_preview.url}
                        </div>
                        <%= if Elektrine.Strings.present?(reply_link_preview.description) do %>
                          <div class="text-xs text-base-content/70 line-clamp-3">
                            {reply_link_preview.description}
                          </div>
                        <% end %>
                        <div class="text-[11px] text-base-content/50 truncate">
                          {safe_reply_preview_url}
                        </div>
                      </div>
                    </a>
                  <% end %>
                <% end %>
              </div>
            <% end %>
            
    <!-- Comment Actions -->
            <div class="relative z-20 pointer-events-auto">
              <.post_actions
                post_id={reply_local_message_id || reply_view.action_post_id}
                value_name={if(reply_local_message_id, do: "message_id", else: "post_id")}
                current_user={@current_user}
                is_liked={is_reply_liked}
                is_boosted={is_reply_boosted}
                like_count={reply_like_count}
                boost_count={reply_boost_count}
                comment_count={reply_child_count}
                on_comment="toggle_comment_reply"
                comment_value_name="comment_id"
                comment_post_id={reply_view.activitypub_id}
                comment_active={reply_view.replying?}
                show_quote={false}
                show_react={false}
                show_save={false}
                dom_id_prefix={reply_view.card_dom_id}
                size={:xs}
              />
            </div>

            <%= if reply_reaction.target_id do %>
              <div class="relative z-20 pointer-events-auto mt-2">
                <.post_reactions
                  post_id={reply_reaction.target_id}
                  value_name={reply_reaction.value_name}
                  reactions={reply_reaction.reactions}
                  current_user={@current_user}
                  size={:xs}
                  portal={false}
                />
              </div>
            <% end %>
            
    <!-- Inline Reply Form -->
            <%= if @current_user && reply_view.replying? do %>
              <form phx-submit="submit_comment_reply" class="relative z-20 pointer-events-auto mt-3">
                <div class="flex gap-2">
                  <textarea
                    name="content"
                    phx-keyup="update_comment_reply_content"
                    value={@comment_reply_content}
                    placeholder="Write a reply..."
                    class="textarea textarea-bordered textarea-sm flex-1 min-h-[60px]"
                    rows="2"
                  ></textarea>
                </div>
                <div class="flex justify-end gap-2 mt-2">
                  <button
                    type="button"
                    phx-click="toggle_comment_reply"
                    phx-value-comment_id={reply_view.activitypub_id}
                    class="btn btn-ghost btn-xs"
                  >
                    Cancel
                  </button>
                  <button type="submit" class="btn btn-secondary btn-xs">
                    Reply
                  </button>
                </div>
              </form>
            <% end %>
          </div>
        <% end %>
        
    <!-- Nested Replies -->
        <%= if (children) != [] do %>
          {render_threaded_comments(assigns, children)}
        <% end %>
      </div>
    <% end %>
    """
  end

  defp reply_view_model(assigns, node) when is_map(node) do
    reply = Map.get(node, :reply, %{})
    children = Map.get(node, :children, [])
    depth = Map.get(node, :depth, 0)
    activitypub_id = map_get_value(reply, "id")
    local_message_id = map_get_value(reply, "_local_message_id")
    local_activitypub_id = map_get_value(reply, "_local_activitypub_id")
    surface_ref = reply_surface_ref(reply)
    reply_state = reply_interaction_state(Map.get(assigns, :post_interactions, %{}), reply)
    like_delta = Map.get(reply_state, :like_delta, 0)
    boost_delta = Map.get(reply_state, :boost_delta, 0)
    vote_delta = Map.get(reply_state, :vote_delta, 0)
    lemmy_data = map_get_value(reply, "_lemmy")

    lemmy_comment_count =
      Map.get(Map.get(assigns, :lemmy_comment_counts, %{}) || %{}, surface_ref)

    score_delta =
      if Map.get(assigns, :is_lemmy_post, false), do: vote_delta, else: like_delta

    reply_author_uri =
      normalize_in_reply_to_ref(map_get_value(reply, "attributedTo")) ||
        normalize_in_reply_to_ref(map_get_value(reply, "actor"))

    local_user = map_get_value(reply, "_local_user")
    local? = map_get_value(reply, "_local") == true
    reply_actor = reply_view_actor(assigns, reply_author_uri, local?, local_user)
    reply_fallback = SurfaceHelpers.build_reply_author_fallback(reply, reply_author_uri)

    render_domain =
      reply_render_domain(reply, reply_actor, Map.get(assigns, :reply_content_domain))

    mention_hints = reply_mention_domain_hints(reply)
    content = map_get_value(reply, "content")
    published = map_get_value(reply, "published")
    card_post_id = local_message_id || activitypub_id || "unknown"

    %{
      source: reply,
      activitypub_id: activitypub_id,
      local_message_id: local_message_id,
      surface_ref: surface_ref,
      dom_id: SurfaceHelpers.reply_dom_id(reply),
      card_dom_id: "reply-card-" <> URI.encode_www_form(to_string(card_post_id)),
      card_post_id: card_post_id,
      action_post_id: if(local_message_id, do: nil, else: activitypub_id),
      children: children,
      depth: depth,
      tree_depth: min(depth, 4),
      liked: Map.get(reply_state, :liked, false),
      boosted: Map.get(reply_state, :boosted, false),
      vote: Map.get(reply_state, :vote, nil),
      like_count: reply_like_count(reply, lemmy_data, lemmy_comment_count, score_delta),
      boost_count: reply_boost_count(reply, boost_delta),
      child_count: reply_child_count(reply, lemmy_data, lemmy_comment_count, children),
      reaction:
        SurfaceHelpers.thread_reply_reaction_surface(
          reply,
          Map.get(assigns, :post_reactions, %{})
        ),
      submitted_url: map_get_value(reply, "_submitted_url"),
      youtube_id: map_get_value(reply, "_youtube_id"),
      link_preview: map_get_value(reply, "_link_preview"),
      click: reply_click_target(local_message_id, local_activitypub_id, activitypub_id),
      local?: local?,
      local_user: local_user,
      actor: reply_actor,
      avatar_url: reply_avatar_url(reply_actor, reply_fallback),
      profile_path: reply_profile_path(reply_actor, reply_fallback),
      display_name: reply_display_name(reply_actor, reply_fallback),
      acct_label: reply_acct_label(reply_actor, reply_fallback),
      published_label: if(published, do: format_activitypub_date(published)),
      content_html:
        if(is_binary(content),
          do: render_remote_post_content(content, render_domain, mention_hints)
        ),
      replying?: Map.get(assigns, :replying_to_comment_id) == activitypub_id
    }
  end

  defp reply_view_model(_assigns, _), do: reply_view_model(%{}, %{reply: %{}})

  defp reply_view_actor(assigns, reply_author_uri, local?, local_user) do
    cond do
      local? && local_user ->
        nil

      is_binary(reply_author_uri) ->
        Map.get(Map.get(assigns, :thread_reply_actors, %{}) || %{}, reply_author_uri)

      true ->
        nil
    end
  end

  defp reply_like_count(reply, lemmy_data, lemmy_comment_count, score_delta) do
    cond do
      is_integer(map_get_value(lemmy_data, "upvotes")) ->
        max(map_get_value(lemmy_data, "upvotes") + score_delta, 0)

      is_integer(map_get_value(lemmy_data, "score")) ->
        max(map_get_value(lemmy_data, "score") + score_delta, 0)

      lemmy_comment_count ->
        max(
          (map_get_value(lemmy_comment_count, "upvotes") ||
             map_get_value(lemmy_comment_count, "score") || 0) + score_delta,
          0
        )

      is_integer(map_get_value(reply, "_local_like_count")) ->
        max(map_get_value(reply, "_local_like_count") + score_delta, 0)

      true ->
        get_collection_total_items(map_get_value(reply, "likes")) + score_delta
    end
  end

  defp reply_boost_count(reply, boost_delta) do
    local_share_count = map_get_value(reply, "_local_share_count")

    if is_integer(local_share_count) do
      max(local_share_count + boost_delta, 0)
    else
      max(get_collection_total_items(map_get_value(reply, "shares")) + boost_delta, 0)
    end
  end

  defp reply_child_count(reply, lemmy_data, lemmy_comment_count, children) do
    cond do
      map_get_value(lemmy_data, "child_count") ->
        map_get_value(lemmy_data, "child_count")

      lemmy_comment_count ->
        map_get_value(lemmy_comment_count, "child_count") || length(children)

      is_integer(map_get_value(reply, "_local_reply_count")) ->
        max(map_get_value(reply, "_local_reply_count"), length(children))

      get_collection_total_items(map_get_value(reply, "replies")) > 0 ->
        max(get_collection_total_items(map_get_value(reply, "replies")), length(children))

      true ->
        length(children)
    end
  end

  defp reply_click_target(local_message_id, local_activitypub_id, activitypub_id) do
    cond do
      is_integer(local_message_id) ->
        %{event: "navigate_to_post", id: local_message_id, post_id: nil}

      Elektrine.Strings.present?(local_activitypub_id) ->
        %{event: "navigate_to_remote_post", id: nil, post_id: local_activitypub_id}

      Elektrine.Strings.present?(activitypub_id) ->
        %{event: "navigate_to_remote_post", id: nil, post_id: activitypub_id}

      true ->
        nil
    end
  end

  defp reply_avatar_url(reply_actor, reply_fallback) do
    if reply_actor && Elektrine.Strings.present?(reply_actor.avatar_url) do
      safe_external_image_url(reply_actor.avatar_url)
    else
      reply_fallback.avatar_url
    end
  end

  defp reply_profile_path(reply_actor, reply_fallback) do
    cond do
      reply_actor -> "/remote/#{reply_actor.username}@#{reply_actor.domain}"
      is_binary(reply_fallback.profile_path) -> reply_fallback.profile_path
      true -> nil
    end
  end

  defp reply_display_name(reply_actor, reply_fallback) do
    if reply_actor,
      do: reply_actor.display_name || reply_actor.username,
      else: reply_fallback.display_name
  end

  defp reply_acct_label(reply_actor, reply_fallback) do
    if reply_actor,
      do: "@#{reply_actor.username}@#{reply_actor.domain}",
      else: reply_fallback.acct_label
  end

  defp reply_interaction_state(post_interactions, reply) when is_map(reply) do
    [reply["_local_message_id"], reply_surface_ref(reply)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&PostInteractions.normalize_key/1)
    |> Enum.find_value(fn key -> Map.get(post_interactions, key) end)
    |> case do
      nil ->
        %{liked: false, like_delta: 0, boosted: false, boost_delta: 0, vote: nil, vote_delta: 0}

      state ->
        state
    end
  end

  defp reply_interaction_state(_, _),
    do: %{liked: false, like_delta: 0, boosted: false, boost_delta: 0, vote: nil, vote_delta: 0}

  defp reply_surface_ref(reply) when is_map(reply) do
    reply["id"] || reply[:id] || reply["_local_activitypub_id"] || reply[:_local_activitypub_id]
  end

  defp reply_surface_ref(_), do: nil

  defp reply_render_domain(reply, reply_actor, fallback_domain) do
    cond do
      is_map(reply_actor) && is_binary(reply_actor.domain) && reply_actor.domain != "" ->
        reply_actor.domain

      host = host_from_reply_actor_ref(reply) ->
        host

      is_binary(fallback_domain) && fallback_domain != "" ->
        fallback_domain

      true ->
        nil
    end
  end

  defp reply_mention_domain_hints(reply) do
    reply
    |> field_value(["inReplyToAuthor", "in_reply_to_author"])
    |> short_mention_domain_hints()
  end

  defp host_from_reply_actor_ref(reply) do
    reply
    |> field_value(["attributedTo", "actor"])
    |> normalize_in_reply_to_ref()
    |> UrlHelpers.host_from_url()
  end

  defp short_mention_domain_hints(author) when is_binary(author) do
    case Regex.run(
           ~r/^@([a-zA-Z0-9_][a-zA-Z0-9_-]*)@([a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9])$/,
           String.trim(author)
         ) do
      [_, username, domain] -> %{String.downcase(username) => domain}
      _ -> %{}
    end
  end

  defp short_mention_domain_hints(_), do: %{}

  defp field_value(nil, _keys), do: nil

  defp field_value(value, keys) when is_list(keys) do
    Enum.find_value(keys, &field_value(value, &1))
  end

  defp field_value(%_{} = value, key) when is_atom(key), do: Map.get(value, key)
  defp field_value(%{} = value, key), do: map_get_value(value, key)
  defp field_value(_, _), do: nil

  defp map_get_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        existing_atom_map_value(map, key)
    end
  end

  defp map_get_value(_, _), do: nil

  defp existing_atom_map_value(map, key) do
    Map.get(map, remote_post_atom_key(key))
  end

  defp remote_post_atom_key("id"), do: :id
  defp remote_post_atom_key("_local_message_id"), do: :_local_message_id
  defp remote_post_atom_key("_local_activitypub_id"), do: :_local_activitypub_id
  defp remote_post_atom_key("_lemmy"), do: :_lemmy
  defp remote_post_atom_key("attributedTo"), do: :attributedTo
  defp remote_post_atom_key("actor"), do: :actor
  defp remote_post_atom_key("_local_user"), do: :_local_user
  defp remote_post_atom_key("_local"), do: :_local
  defp remote_post_atom_key("content"), do: :content
  defp remote_post_atom_key("published"), do: :published
  defp remote_post_atom_key("_submitted_url"), do: :_submitted_url
  defp remote_post_atom_key("_youtube_id"), do: :_youtube_id
  defp remote_post_atom_key("_link_preview"), do: :_link_preview
  defp remote_post_atom_key("upvotes"), do: :upvotes
  defp remote_post_atom_key("score"), do: :score
  defp remote_post_atom_key("_local_like_count"), do: :_local_like_count
  defp remote_post_atom_key("likes"), do: :likes
  defp remote_post_atom_key("_local_share_count"), do: :_local_share_count
  defp remote_post_atom_key("shares"), do: :shares
  defp remote_post_atom_key("child_count"), do: :child_count
  defp remote_post_atom_key("inReplyToAuthor"), do: :inReplyToAuthor
  defp remote_post_atom_key("in_reply_to_author"), do: :in_reply_to_author
  defp remote_post_atom_key(_), do: nil

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

  defp get_collection_total_items(collection), do: APHelpers.get_collection_total(collection)

  defp format_activitypub_date(date), do: APHelpers.format_activitypub_date(date)
end
