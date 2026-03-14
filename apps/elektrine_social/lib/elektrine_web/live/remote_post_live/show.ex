defmodule ElektrineWeb.RemotePostLive.Show do
  use ElektrineSocialWeb, :live_view

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias Elektrine.ActivityPub.LemmyApi
  alias Elektrine.Messaging
  alias Elektrine.Social
  alias ElektrineWeb.Components.Social.PostUtilities
  alias ElektrineWeb.Live.PostInteractions
  alias ElektrineWeb.RemotePostLive.{Interactions, SurfaceHelpers, Threading}

  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.Components.Social.TimelinePost, only: [timeline_post: 1]
  import ElektrineWeb.HtmlHelpers
  import ElektrineWeb.Components.Loaders.Skeleton

  @submitted_preview_poll_attempts 10
  @submitted_preview_poll_interval_ms 1_000

  # Render threaded comments recursively
  # Detects if this is a Lemmy post (has community_actor) and renders accordingly
  def render_threaded_comments(assigns, comments) do
    # Determine if this is a Lemmy post based on presence of community_actor
    is_lemmy_post = assigns[:community_actor] != nil
    reply_content_domain = if(assigns[:remote_actor], do: assigns.remote_actor.domain, else: nil)

    thread_reply_actors =
      assigns[:thread_reply_actors] || Threading.build_thread_reply_actor_cache(comments)

    assigns =
      assigns
      |> assign(:comments, comments)
      |> assign(:is_lemmy_post, is_lemmy_post)
      |> assign(:post_reactions, assigns[:post_reactions] || %{})
      |> assign(:thread_reply_actors, thread_reply_actors)
      |> assign(:reply_content_domain, reply_content_domain)

    ~H"""
    <%= for node <- @comments do %>
      <% reply = node.reply %>
      <% depth = node.depth %>
      <% children = node.children %>
      <% reply_state =
        Map.get(@post_interactions, reply["id"], %{
          liked: false,
          like_delta: 0,
          vote: nil,
          vote_delta: 0
        })

      is_reply_liked = Map.get(reply_state, :liked, false)
      reply_like_delta = Map.get(reply_state, :like_delta, 0)
      user_vote = Map.get(reply_state, :vote, nil)
      vote_delta = Map.get(reply_state, :vote_delta, 0)
      # Use embedded Lemmy counts if available, then try separate fetch, then fall back to ActivityPub
      lemmy_data = reply["_lemmy"]
      lemmy_comment_count = Map.get(@lemmy_comment_counts || %{}, reply["id"])

      # For community posts, use vote_delta; for regular posts, use like_delta
      score_delta = if @is_lemmy_post, do: vote_delta, else: reply_like_delta

      reply_like_count =
        cond do
          lemmy_data && lemmy_data["score"] ->
            lemmy_data["score"] + score_delta

          lemmy_comment_count ->
            lemmy_comment_count.score + score_delta

          true ->
            (get_collection_total_items(reply["likes"]) || 0) + score_delta
        end

      reply_child_count =
        cond do
          lemmy_data && lemmy_data["child_count"] -> lemmy_data["child_count"]
          lemmy_comment_count -> lemmy_comment_count.child_count
          true -> length(children)
        end

      reply_reaction = SurfaceHelpers.thread_reply_reaction_surface(reply, @post_reactions)

      is_local_reply = reply["_local"] == true
      local_user = reply["_local_user"]

      reply_author_uri =
        normalize_in_reply_to_ref(reply["attributedTo"]) ||
          normalize_in_reply_to_ref(reply["actor"])

      reply_actor =
        cond do
          # We'll use local_user directly
          is_local_reply && local_user -> nil
          is_binary(reply_author_uri) -> Map.get(@thread_reply_actors, reply_author_uri)
          true -> nil
        end

      reply_fallback = SurfaceHelpers.build_reply_author_fallback(reply, reply_author_uri)

      reply_avatar_url =
        cond do
          reply_actor && is_binary(reply_actor.avatar_url) &&
              String.trim(reply_actor.avatar_url) != "" ->
            reply_actor.avatar_url

          true ->
            reply_fallback.avatar_url
        end

      reply_profile_path =
        cond do
          reply_actor -> "/remote/#{reply_actor.username}@#{reply_actor.domain}"
          is_binary(reply_fallback.profile_path) -> reply_fallback.profile_path
          true -> nil
        end

      reply_display_name =
        cond do
          reply_actor -> reply_actor.display_name || reply_actor.username
          true -> reply_fallback.display_name
        end

      reply_acct_label =
        cond do
          reply_actor -> "@#{reply_actor.username}@#{reply_actor.domain}"
          true -> reply_fallback.acct_label
        end

      # Keep visual distinction by surface: threaded trees for communities,
      # conversational rails for timeline-style threads.
      indent_class =
        if @is_lemmy_post do
          case min(depth, 4) do
            0 -> ""
            1 -> "border-l-2 border-secondary/55 pl-3 ml-2"
            2 -> "border-l-2 border-info/55 pl-3 ml-4"
            3 -> "border-l-2 border-warning/55 pl-3 ml-6"
            _ -> "border-l-2 border-success/50 pl-3 ml-8"
          end
        else
          case min(depth, 2) do
            0 -> ""
            1 -> "border-l-2 border-secondary/50 pl-3 ml-2"
            _ -> "border-l-2 border-info/45 pl-3 ml-2"
          end
        end %>
      <div id={SurfaceHelpers.reply_dom_id(reply)} class={indent_class}>
        <%= if @is_lemmy_post do %>
          <!-- Lemmy-style comment (Reddit-style with vote column) -->
          <div class="flex gap-2 mb-2">
            <!-- Vote Column -->
            <div class="flex flex-col items-center gap-0.5 flex-shrink-0 pt-1">
              <%= if @current_user do %>
                <button
                  phx-click="vote_comment"
                  phx-value-comment_id={reply["id"]}
                  phx-value-type="up"
                  class={[
                    "p-0.5 rounded transition-colors",
                    if(user_vote == "up",
                      do: "text-success",
                      else: "text-base-content/40 hover:text-success"
                    )
                  ]}
                  type="button"
                >
                  <.icon
                    name={if user_vote == "up", do: "hero-arrow-up-solid", else: "hero-arrow-up"}
                    class="w-4 h-4"
                  />
                </button>
              <% else %>
                <div class="p-0.5 text-base-content/30">
                  <.icon name="hero-arrow-up" class="w-4 h-4" />
                </div>
              <% end %>
              <span class={[
                "text-xs font-medium",
                cond do
                  user_vote == "up" -> "text-success"
                  user_vote == "down" -> "text-error"
                  true -> "text-base-content/60"
                end
              ]}>
                {reply_like_count}
              </span>
              <%= if @current_user do %>
                <button
                  phx-click="vote_comment"
                  phx-value-comment_id={reply["id"]}
                  phx-value-type="down"
                  class={[
                    "p-0.5 rounded transition-colors",
                    if(user_vote == "down",
                      do: "text-error",
                      else: "text-base-content/40 hover:text-error"
                    )
                  ]}
                  type="button"
                >
                  <.icon
                    name={
                      if user_vote == "down", do: "hero-arrow-down-solid", else: "hero-arrow-down"
                    }
                    class="w-4 h-4"
                  />
                </button>
              <% else %>
                <div class="p-0.5 text-base-content/30">
                  <.icon name="hero-arrow-down" class="w-4 h-4" />
                </div>
              <% end %>
            </div>
            
    <!-- Comment Content -->
            <div class="flex-1 min-w-0">
              <!-- Comment Header -->
              <div class="flex items-center gap-2 text-xs mb-1 min-w-0">
                <%= if is_local_reply && local_user do %>
                  <.link
                    navigate={"/#{local_user.handle || local_user.username}"}
                    class="flex-shrink-0"
                    aria-label={"Open #{local_user.display_name || local_user.username} profile"}
                  >
                    <%= if local_user.avatar do %>
                      <img
                        src={Elektrine.Uploads.avatar_url(local_user.avatar)}
                        alt=""
                        class="w-6 h-6 rounded-full object-cover"
                      />
                    <% else %>
                      <div class="w-6 h-6 rounded-full bg-base-300 flex items-center justify-center">
                        <.icon name="hero-user" class="w-3 h-3 opacity-60" />
                      </div>
                    <% end %>
                  </.link>
                  <.link
                    navigate={"/#{local_user.handle || local_user.username}"}
                    class="font-medium text-info hover:underline truncate"
                  >
                    {local_user.display_name || local_user.username}
                  </.link>
                  <%= if @current_user && @current_user.id == local_user.id do %>
                    <span class="text-info/70">(you)</span>
                  <% end %>
                <% else %>
                  <%= if reply_profile_path do %>
                    <.link
                      navigate={reply_profile_path}
                      class="flex-shrink-0"
                      aria-label={"Open #{reply_display_name} profile"}
                    >
                      <%= if is_binary(reply_avatar_url) && String.trim(reply_avatar_url) != "" do %>
                        <img
                          src={reply_avatar_url}
                          alt=""
                          class="w-6 h-6 rounded-full object-cover"
                        />
                      <% else %>
                        <div class="w-6 h-6 rounded-full bg-base-300 flex items-center justify-center">
                          <.icon name="hero-user" class="w-3 h-3 opacity-60" />
                        </div>
                      <% end %>
                    </.link>
                    <.link navigate={reply_profile_path} class="font-medium hover:underline truncate">
                      <%= if reply_actor do %>
                        {raw(
                          render_display_name_with_emojis(
                            reply_actor.display_name || reply_actor.username,
                            reply_actor.domain
                          )
                        )}
                      <% else %>
                        {reply_display_name}
                      <% end %>
                    </.link>
                  <% else %>
                    <%= if is_binary(reply_avatar_url) && String.trim(reply_avatar_url) != "" do %>
                      <img
                        src={reply_avatar_url}
                        alt=""
                        class="w-6 h-6 rounded-full object-cover flex-shrink-0"
                        aria-hidden="true"
                      />
                    <% else %>
                      <div class="w-6 h-6 rounded-full bg-base-300 flex items-center justify-center flex-shrink-0">
                        <.icon name="hero-user" class="w-3 h-3 opacity-60" />
                      </div>
                    <% end %>
                    <span class="font-medium truncate">{reply_display_name}</span>
                  <% end %>
                <% end %>
                <span class="text-base-content/40">·</span>
                <span class="text-base-content/50">
                  {if reply["published"], do: format_activitypub_date(reply["published"])}
                </span>
              </div>
              
    <!-- Comment Text -->
              <%= if reply["content"] do %>
                <div class="text-sm leading-relaxed mb-1.5 post-content">
                  {raw(render_remote_post_content(reply["content"], @reply_content_domain))}
                </div>
              <% end %>
              
    <!-- Reply Action -->
              <%= if @current_user do %>
                <button
                  phx-click="toggle_comment_reply"
                  phx-value-comment_id={reply["id"]}
                  class={[
                    "text-xs transition-colors",
                    if(@replying_to_comment_id == reply["id"],
                      do: "text-secondary font-medium",
                      else: "text-base-content/50 hover:text-secondary"
                    )
                  ]}
                  type="button"
                >
                  <%= if reply_child_count > 0 do %>
                    {reply_child_count} replies
                  <% else %>
                    Reply
                  <% end %>
                </button>
              <% else %>
                <%= if reply_child_count > 0 do %>
                  <span class="text-xs text-base-content/40">{reply_child_count} replies</span>
                <% end %>
              <% end %>

              <%= if reply_reaction.target_id do %>
                <div class="mt-2" phx-click="stop_propagation">
                  <.post_reactions
                    post_id={reply_reaction.target_id}
                    value_name={reply_reaction.value_name}
                    reactions={reply_reaction.reactions}
                    current_user={@current_user}
                    size={:xs}
                  />
                </div>
              <% end %>
              
    <!-- Inline Reply Form -->
              <%= if @current_user && @replying_to_comment_id == reply["id"] do %>
                <form phx-submit="submit_comment_reply" class="mt-2">
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
                      phx-value-comment_id={reply["id"]}
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
          <div class="bg-base-200/50 rounded-lg p-3 mb-2">
            <!-- Comment Header -->
            <div class="flex items-center gap-2 mb-2">
              <%= if is_local_reply && local_user do %>
                <!-- Local user reply -->
                <.link
                  navigate={"/#{local_user.handle || local_user.username}"}
                  class="flex-shrink-0"
                  aria-label={"Open #{local_user.display_name || local_user.username} profile"}
                >
                  <%= if local_user.avatar do %>
                    <img
                      src={Elektrine.Uploads.avatar_url(local_user.avatar)}
                      alt=""
                      class="w-8 h-8 rounded-full"
                    />
                  <% else %>
                    <div class="w-8 h-8 rounded-full bg-gradient-to-br from-purple-600 to-pink-600 text-white flex items-center justify-center">
                      <.icon name="hero-user" class="w-4 h-4" />
                    </div>
                  <% end %>
                </.link>
                <div class="flex-1 min-w-0">
                  <.link
                    navigate={"/#{local_user.handle || local_user.username}"}
                    class="text-sm font-medium hover:text-error transition-colors"
                  >
                    {local_user.display_name || local_user.username}
                  </.link>
                  <%= if @current_user && @current_user.id == local_user.id do %>
                    <span class="text-xs text-info ml-1">(you)</span>
                  <% end %>
                  <div class="text-xs opacity-50">
                    {if reply["published"], do: format_activitypub_date(reply["published"])}
                  </div>
                </div>
              <% else %>
                <%= if reply_profile_path do %>
                  <.link
                    navigate={reply_profile_path}
                    class="flex-shrink-0"
                    aria-label={"Open #{reply_display_name} profile"}
                  >
                    <%= if is_binary(reply_avatar_url) && String.trim(reply_avatar_url) != "" do %>
                      <img
                        src={reply_avatar_url}
                        alt=""
                        class="w-8 h-8 rounded-full object-cover"
                      />
                    <% else %>
                      <div class="w-8 h-8 rounded-full bg-base-300 flex items-center justify-center">
                        <.icon name="hero-user" class="w-4 h-4 opacity-70" />
                      </div>
                    <% end %>
                  </.link>
                <% else %>
                  <%= if is_binary(reply_avatar_url) && String.trim(reply_avatar_url) != "" do %>
                    <img
                      src={reply_avatar_url}
                      alt=""
                      class="w-8 h-8 rounded-full object-cover flex-shrink-0"
                      aria-hidden="true"
                    />
                  <% else %>
                    <div class="w-8 h-8 rounded-full bg-base-300 flex items-center justify-center flex-shrink-0">
                      <.icon name="hero-user" class="w-4 h-4 opacity-70" />
                    </div>
                  <% end %>
                <% end %>
                <div class="flex-1 min-w-0">
                  <%= if reply_profile_path do %>
                    <.link
                      navigate={reply_profile_path}
                      class="text-sm font-medium hover:text-purple-600 transition-colors"
                    >
                      <%= if reply_actor do %>
                        {raw(
                          render_display_name_with_emojis(
                            reply_actor.display_name || reply_actor.username,
                            reply_actor.domain
                          )
                        )}
                      <% else %>
                        {reply_display_name}
                      <% end %>
                    </.link>
                  <% else %>
                    <span class="text-sm font-medium">{reply_display_name}</span>
                  <% end %>
                  <div class="text-xs opacity-50">
                    <%= if is_binary(reply_acct_label) && String.trim(reply_acct_label) != "" do %>
                      {reply_acct_label} ·
                    <% end %>
                    {if reply["published"], do: format_activitypub_date(reply["published"])}
                  </div>
                </div>
              <% end %>
            </div>

            <%= if depth > 0 do %>
              <div class="text-xs text-base-content/60 mb-2 flex items-center gap-1">
                <.icon name="hero-arrow-uturn-left" class="w-3 h-3" /> Thread reply
              </div>
            <% end %>
            
    <!-- Comment Content -->
            <%= if reply["content"] do %>
              <div class="text-sm leading-relaxed mb-2 post-content">
                {raw(render_remote_post_content(reply["content"], @reply_content_domain))}
              </div>
            <% end %>
            
    <!-- Comment Actions -->
            <%= if @current_user do %>
              <div class="flex items-center gap-4 text-xs">
                <button
                  phx-click={if is_reply_liked, do: "unlike_post", else: "like_post"}
                  phx-value-post_id={reply["id"]}
                  class={[
                    "flex items-center gap-1 transition-colors",
                    if(is_reply_liked, do: "text-error", else: "opacity-60 hover:text-error")
                  ]}
                  type="button"
                >
                  <.icon
                    name={if is_reply_liked, do: "hero-heart-solid", else: "hero-heart"}
                    class={["w-4 h-4", is_reply_liked && "text-error"]}
                  />
                  <%= if reply_like_count > 0 do %>
                    <span>{reply_like_count}</span>
                  <% end %>
                </button>
                <button
                  phx-click="toggle_comment_reply"
                  phx-value-comment_id={reply["id"]}
                  class={[
                    "flex items-center gap-1 transition-colors",
                    if(@replying_to_comment_id == reply["id"],
                      do: "text-secondary",
                      else: "opacity-60 hover:text-secondary"
                    )
                  ]}
                  type="button"
                >
                  <.icon name="hero-chat-bubble-left" class="w-4 h-4" />
                  <%= if reply_child_count > 0 do %>
                    <span>{reply_child_count}</span>
                  <% else %>
                    <span>Reply</span>
                  <% end %>
                </button>
              </div>
            <% else %>
              <div class="flex items-center gap-4 text-xs opacity-50">
                <div class="flex items-center gap-1">
                  <.icon name="hero-heart" class="w-4 h-4" />
                  <%= if reply_like_count > 0 do %>
                    <span>{reply_like_count}</span>
                  <% end %>
                </div>
                <%= if reply_child_count > 0 do %>
                  <div class="flex items-center gap-1">
                    <.icon name="hero-chat-bubble-left" class="w-4 h-4" />
                    <span>{reply_child_count}</span>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%= if reply_reaction.target_id do %>
              <div class="mt-2" phx-click="stop_propagation">
                <.post_reactions
                  post_id={reply_reaction.target_id}
                  value_name={reply_reaction.value_name}
                  reactions={reply_reaction.reactions}
                  current_user={@current_user}
                  size={:xs}
                />
              </div>
            <% end %>
            
    <!-- Inline Reply Form -->
            <%= if @current_user && @replying_to_comment_id == reply["id"] do %>
              <form phx-submit="submit_comment_reply" class="mt-3">
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
                    phx-value-comment_id={reply["id"]}
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

  attr :in_reply_to, :string, default: nil
  attr :reply_parent, :map, default: nil
  attr :reply_parent_actor, :map, default: nil
  attr :reply_ancestors, :list, default: []
  attr :post_interactions, :map, default: %{}
  attr :user_saves, :map, default: %{}
  attr :post_reactions, :map, default: %{}
  attr :current_user, :map, default: nil
  attr :replying_to_comment_id, :any, default: nil
  attr :comment_reply_content, :string, default: ""

  def ancestor_context_stack(assigns) do
    ~H"""
    <%= if @in_reply_to do %>
      <% fallback_entry =
        if is_map(@reply_parent) do
          [
            %{
              post: @reply_parent,
              actor: @reply_parent_actor,
              in_reply_to: @in_reply_to
            }
          ]
        else
          []
        end

      ancestors_for_render =
        if Enum.empty?(@reply_ancestors),
          do: fallback_entry,
          else: @reply_ancestors

      ancestors_for_render = Enum.reverse(ancestors_for_render)
      ancestor_count = length(ancestors_for_render) %>
      <%= if ancestors_for_render != [] do %>
        <section class="mb-4 space-y-2" aria-label="Conversation context">
          <%= for {ancestor, idx} <- Enum.with_index(ancestors_for_render) do %>
            <% parent_post = ancestor.post
            parent_actor = ancestor.actor

            parent_ref = ancestor_post_ref(parent_post, ancestor.in_reply_to)

            parent_author = reply_parent_author_label(parent_post, parent_actor)

            parent_domain =
              reply_parent_content_domain(parent_post, parent_actor, parent_ref)

            parent_title =
              if is_map(parent_post), do: parent_post["name"], else: nil

            parent_content =
              if is_map(parent_post), do: parent_post["content"], else: nil

            interaction =
              SurfaceHelpers.ancestor_interaction_target(parent_post, ancestor.in_reply_to)

            post_state =
              if interaction do
                Map.get(@post_interactions, interaction.interaction_key, %{
                  liked: false,
                  boosted: false,
                  like_delta: 0,
                  boost_delta: 0
                })
              else
                %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}
              end

            is_liked = Map.get(post_state, :liked, false)
            is_boosted = Map.get(post_state, :boosted, false)
            like_count = SurfaceHelpers.ancestor_like_count(parent_post, post_state)
            boost_count = SurfaceHelpers.ancestor_boost_count(parent_post, post_state)
            reply_count = SurfaceHelpers.ancestor_reply_count(parent_post)

            is_saved =
              if interaction,
                do: Map.get(@user_saves, interaction.interaction_key, false),
                else: false

            local_parent_id = SurfaceHelpers.ancestor_local_message_id(parent_post)
            has_external_link = http_url?(parent_ref)
            role_label = SurfaceHelpers.ancestor_role_label(idx, ancestor_count)
            color = SurfaceHelpers.ancestor_thread_colors(idx) %>
            <div class="flex items-stretch gap-3">
              <div class="relative flex w-4 flex-shrink-0 justify-center">
                <%= if idx < ancestor_count - 1 do %>
                  <div class={[
                    "absolute left-1/2 top-5 bottom-0 w-0.5 -translate-x-1/2 rounded-full",
                    color.rail
                  ]}>
                  </div>
                <% end %>
                <div class={[
                  "mt-2 h-2.5 w-2.5 rounded-full ring-2 ring-base-100",
                  color.dot
                ]}>
                </div>
              </div>
              <article class={[
                "flex-1 rounded-xl border border-base-300 border-l-4 bg-base-200/50 p-3",
                color.border
              ]}>
                <div class="flex items-start gap-2 min-w-0">
                  <%= if parent_actor && is_binary(parent_actor.avatar_url) && parent_actor.avatar_url != "" do %>
                    <img
                      src={parent_actor.avatar_url}
                      alt=""
                      class="w-7 h-7 rounded-full object-cover flex-shrink-0 mt-0.5"
                    />
                  <% else %>
                    <div class="w-7 h-7 rounded-full bg-base-300 flex items-center justify-center flex-shrink-0 mt-0.5">
                      <.icon name="hero-user" class="w-4 h-4 opacity-60" />
                    </div>
                  <% end %>
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2 text-xs min-w-0">
                      <span class={[
                        "badge badge-xs flex-shrink-0",
                        SurfaceHelpers.ancestor_role_badge_class(role_label)
                      ]}>
                        {role_label}
                      </span>
                      <span class="opacity-70">Replying to</span>
                      <span class="font-medium truncate">{parent_author}</span>
                      <%= if is_integer(local_parent_id) do %>
                        <.link
                          navigate={"/remote/post/#{local_parent_id}"}
                          class="ml-auto inline-flex items-center gap-1 text-[11px] font-medium text-primary hover:underline"
                        >
                          Open <.icon name="hero-arrow-right" class="w-3 h-3" />
                        </.link>
                      <% else %>
                        <%= if has_external_link do %>
                          <.link
                            navigate={"/remote/post/#{URI.encode_www_form(parent_ref)}"}
                            class="ml-auto inline-flex items-center gap-1 text-[11px] font-medium text-primary hover:underline"
                          >
                            Open <.icon name="hero-arrow-right" class="w-3 h-3" />
                          </.link>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                </div>
                <%= if is_binary(parent_title) && String.trim(parent_title) != "" do %>
                  <div class="mt-2 text-sm font-semibold line-clamp-2 break-words">
                    {parent_title}
                  </div>
                <% end %>
                <%= if is_binary(parent_content) && String.trim(parent_content) != "" do %>
                  <div class="mt-1 text-sm opacity-80 line-clamp-4 break-words post-content">
                    {raw(render_remote_post_content(parent_content, parent_domain))}
                  </div>
                <% end %>
                <%= if is_integer(local_parent_id) do %>
                  <div class="mt-2 flex flex-wrap items-center gap-3 text-xs">
                    <.link
                      navigate={"/remote/post/#{local_parent_id}"}
                      class="inline-flex items-center gap-1 font-medium text-primary hover:underline"
                    >
                      Open parent post <.icon name="hero-arrow-right" class="w-3 h-3" />
                    </.link>
                    <%= if has_external_link do %>
                      <a
                        href={parent_ref}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="inline-flex items-center gap-1 text-base-content/70 hover:text-primary hover:underline"
                      >
                        Original URL <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                      </a>
                    <% end %>
                  </div>
                <% else %>
                  <%= if has_external_link do %>
                    <.link
                      navigate={"/remote/post/#{URI.encode_www_form(parent_ref)}"}
                      class="mt-2 inline-flex items-center gap-1 text-xs font-medium text-primary hover:underline"
                    >
                      View parent post <.icon name="hero-arrow-right" class="w-3 h-3" />
                    </.link>
                  <% else %>
                    <div class="mt-2 text-xs opacity-60 break-all">
                      {parent_ref}
                    </div>
                  <% end %>
                <% end %>
                <%= if interaction do %>
                  <div class="mt-3 pt-3 border-t border-base-300/70 space-y-2">
                    <div class="flex flex-wrap items-center gap-2">
                      <.post_actions
                        post_id={interaction.action_target}
                        value_name={interaction.action_value_name}
                        current_user={@current_user}
                        is_liked={is_liked}
                        is_boosted={is_boosted}
                        like_count={like_count}
                        boost_count={boost_count}
                        comment_count={reply_count}
                        is_saved={is_saved}
                        show_quote={false}
                        show_comment={false}
                        size={:sm}
                      />

                      <%= if @current_user do %>
                        <button
                          phx-click="toggle_comment_reply"
                          phx-value-comment_id={interaction.comment_target}
                          class={[
                            "btn btn-ghost btn-sm px-2 h-8 min-h-8 gap-1",
                            if(
                              @replying_to_comment_id ==
                                interaction.comment_target,
                              do: "bg-secondary/10 text-secondary"
                            )
                          ]}
                          type="button"
                        >
                          <.icon name="hero-chat-bubble-left" class="w-4 h-4" />
                          <span class="text-xs tabular-nums">
                            <%= if reply_count > 0 do %>
                              {reply_count}
                            <% else %>
                              Reply
                            <% end %>
                          </span>
                        </button>
                      <% else %>
                        <div class="btn btn-ghost btn-sm px-2 h-8 min-h-8 gap-1 cursor-default opacity-60">
                          <.icon name="hero-chat-bubble-left" class="w-4 h-4" />
                          <span class="text-xs tabular-nums">{reply_count}</span>
                        </div>
                      <% end %>

                      <.post_reactions
                        post_id={interaction.action_target}
                        value_name={interaction.action_value_name}
                        reactions={Map.get(@post_reactions, interaction.reactions_key, [])}
                        current_user={@current_user}
                        size={:sm}
                      />
                    </div>

                    <%= if @current_user &&
                          @replying_to_comment_id == interaction.comment_target do %>
                      <form phx-submit="submit_comment_reply" class="mt-2">
                        <textarea
                          name="content"
                          phx-keyup="update_comment_reply_content"
                          value={@comment_reply_content}
                          placeholder="Write a reply..."
                          class="textarea textarea-bordered textarea-sm w-full min-h-[70px]"
                          rows="2"
                        ></textarea>
                        <div class="flex justify-end gap-2 mt-2">
                          <button
                            type="button"
                            phx-click="toggle_comment_reply"
                            phx-value-comment_id={interaction.comment_target}
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
              </article>
            </div>
          <% end %>
        </section>
      <% end %>
    <% end %>
    """
  end

  attr :message, :map, required: true
  attr :replies, :list, default: []
  attr :post_interactions, :map, default: %{}
  attr :user_saves, :map, default: %{}
  attr :post_reactions, :map, default: %{}
  attr :current_user, :map, default: nil

  def standard_timeline_detail_post(assigns) do
    message = detail_message_with_reply_count(assigns.message, assigns.replies)
    interaction_state = detail_message_interaction(assigns.post_interactions, message)

    assigns =
      assigns
      |> assign(:message, message)
      |> assign(:interaction_state, interaction_state)
      |> assign(:reactions, detail_message_reactions(assigns.post_reactions, message))
      |> assign(:saved?, detail_message_saved?(assigns.user_saves, message))

    ~H"""
    <.timeline_post
      post={@message}
      current_user={@current_user}
      user_likes={%{@message.id => @interaction_state.liked}}
      user_boosts={%{@message.id => @interaction_state.boosted}}
      user_saves={%{@message.id => @saved?}}
      reactions={@reactions}
      click_event="stop_event"
      source="timeline"
      id_prefix="remote-post-detail"
      show_follow_button={false}
      show_admin_actions={false}
      show_post_dropdown={false}
      on_comment="toggle_reply_form"
      show_quote_button={false}
    />
    """
  end

  attr :replies_loading, :boolean, default: false
  attr :replies_loaded, :boolean, default: false
  attr :empty_message, :string, default: "No comments yet"
  attr :load_label, :string, default: "Load Comments"

  def empty_comments_state(assigns) do
    ~H"""
    <div
      class="card social-page-card border border-base-300 rounded-lg p-4 min-h-[14rem]"
      data-comments-state={if @replies_loading, do: "loading", else: "idle"}
    >
      <%= if @replies_loading do %>
        <div class="space-y-3" data-comments-loading-placeholder>
          <div class="flex items-center gap-2 text-sm font-medium text-base-content/60">
            <.icon name="hero-arrow-path" class="w-4 h-4 animate-spin" /> Loading comments...
          </div>
          <.reply_skeleton />
          <.reply_skeleton />
          <.reply_skeleton />
        </div>
      <% else %>
        <div class="flex min-h-[12rem] flex-col items-center justify-center text-center text-base-content/60">
          <.icon name="hero-chat-bubble-left" class="w-12 h-12 mb-3 opacity-30" />
          <%= if @replies_loaded do %>
            <p>{@empty_message}</p>
          <% else %>
            <button phx-click="load_comments" class="btn btn-primary btn-sm">
              <.icon name="hero-chat-bubble-left-right" class="w-4 h-4" /> {@load_label}
            </button>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :show_reply_form, :boolean, default: false
  attr :current_user, :map, default: nil
  attr :quick_reply_recent_replies, :list, default: []
  attr :reply_content, :string, default: ""
  attr :reply_content_domain, :any, default: nil

  def standard_timeline_detail_reply_box(assigns) do
    ~H"""
    <%= if @show_reply_form && @current_user do %>
      <div class="card social-page-card border border-base-300 rounded-lg p-4 mb-6">
        <div class="space-y-3">
          <%= if length(@quick_reply_recent_replies) > 0 do %>
            <div class="border-l-2 border-cyan-500/60 pl-3 space-y-2">
              <div class="text-xs font-semibold opacity-60">Recent Replies:</div>
              <%= for reply <- @quick_reply_recent_replies do %>
                <% author_preview = quick_reply_author_preview(reply) %>
                <div class="text-sm">
                  <div class="flex items-center gap-2 mb-1 min-w-0">
                    <%= if author_preview.profile_path do %>
                      <.link
                        navigate={author_preview.profile_path}
                        class="w-5 h-5 flex-shrink-0"
                        phx-click="stop_propagation"
                      >
                        <%= if is_binary(author_preview.avatar_url) && String.trim(author_preview.avatar_url) != "" do %>
                          <img
                            src={author_preview.avatar_url}
                            alt=""
                            class="w-5 h-5 rounded-full object-cover"
                          />
                        <% else %>
                          <div class="w-5 h-5 rounded-full bg-base-300 flex items-center justify-center">
                            <.icon name="hero-user" class="w-3 h-3 opacity-60" />
                          </div>
                        <% end %>
                      </.link>
                      <.link
                        navigate={author_preview.profile_path}
                        class="font-medium truncate hover:underline"
                        phx-click="stop_propagation"
                      >
                        {author_preview.label}
                      </.link>
                    <% else %>
                      <%= if is_binary(author_preview.avatar_url) && String.trim(author_preview.avatar_url) != "" do %>
                        <img
                          src={author_preview.avatar_url}
                          alt=""
                          class="w-5 h-5 rounded-full object-cover flex-shrink-0"
                        />
                      <% else %>
                        <div class="w-5 h-5 rounded-full bg-base-300 flex items-center justify-center flex-shrink-0">
                          <.icon name="hero-user" class="w-3 h-3 opacity-60" />
                        </div>
                      <% end %>
                      <span class="font-medium truncate">{author_preview.label}</span>
                    <% end %>
                    <%= if reply["published"] do %>
                      <span class="text-xs opacity-50">
                        · {format_activitypub_date(reply["published"])}
                      </span>
                    <% end %>
                  </div>
                  <div class="text-xs opacity-75 line-clamp-2 break-words">
                    {raw(render_remote_post_content(reply["content"] || "", @reply_content_domain))}
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>

          <ElektrineWeb.Components.Social.RemotePostShared.inline_reply_form
            wrapper_class=""
            content={@reply_content}
            textarea_id="remote-post-reply-textarea"
            textarea_class="textarea textarea-bordered w-full"
            rows={4}
            form_class="space-y-3"
            on_submit="submit_reply"
            on_change="update_reply_content"
            on_cancel="toggle_reply_form"
            cancel_class="btn btn-ghost btn-sm"
            submit_class="btn btn-secondary btn-sm"
            textarea_debounce="300"
            textarea_hook="AutoExpandTextarea"
            submit_label="Reply"
            submit_icon="hero-paper-airplane"
            submit_icon_class="w-4 h-4 mr-1"
            submit_disable_with="Posting..."
            content_min={3}
            counter_suffix={gettext(" required chars")}
            show_counter={true}
          />
        </div>
      </div>
    <% end %>

    <%= if !@current_user do %>
      <div class="card social-page-card border border-base-300 rounded-lg p-4 mb-6 text-center">
        <.link navigate={~p"/login"} class="btn btn-secondary btn-sm">
          Sign in to interact
        </.link>
      </div>
    <% end %>
    """
  end

  defp use_standard_timeline_detail?(message, is_community_post) do
    !is_community_post && is_map(message) &&
      (loaded_assoc?(Map.get(message, :sender)) || loaded_assoc?(Map.get(message, :remote_actor)))
  end

  defp loaded_assoc?(%Ecto.Association.NotLoaded{}), do: false
  defp loaded_assoc?(nil), do: false
  defp loaded_assoc?(_), do: true

  defp detail_message_with_reply_count(message, replies) when is_map(message) do
    %{message | reply_count: max(length(replies), message.reply_count || 0)}
  end

  defp detail_message_interaction(post_interactions, message) do
    post_interactions
    |> PostInteractions.interaction_state(detail_interaction_key(message))
    |> Map.put_new(:liked, false)
    |> Map.put_new(:boosted, false)
  end

  defp detail_message_reactions(post_reactions, message) do
    [message.activitypub_id, message.id]
    |> Enum.filter(& &1)
    |> Enum.map(&PostInteractions.normalize_key/1)
    |> Enum.find_value([], &Map.get(post_reactions, &1))
  end

  defp detail_message_saved?(user_saves, message) do
    [message.activitypub_id, message.id]
    |> Enum.filter(& &1)
    |> Enum.map(&PostInteractions.normalize_key/1)
    |> Enum.any?(&Map.get(user_saves, &1, false))
  end

  defp detail_interaction_key(message) do
    message.activitypub_id || message.id
  end

  @impl true
  def mount(%{"post_id" => post_id}, _session, socket) do
    # post_id could be a URL-encoded ActivityPub ID or a numeric local ID
    decoded_post_id = URI.decode_www_form(post_id)

    # Check if this is a numeric local post ID
    is_local_post =
      case Integer.parse(decoded_post_id) do
        {_num, ""} -> true
        _ -> false
      end

    # Keep layout stable for community-style posts from the first render.
    is_community_post = !is_local_post && community_post_url?(decoded_post_id)

    # Initialize with loading state
    socket =
      socket
      |> assign(:page_title, "Loading post...")
      |> assign(:loading, true)
      |> assign(:load_error, nil)
      |> assign(:post_id, decoded_post_id)
      |> assign(:is_local_post, is_local_post)
      |> assign(:is_community_post, is_community_post)
      |> assign(:local_message, nil)
      |> assign(:post, nil)
      |> assign(:remote_actor, nil)
      |> assign(:community_actor, nil)
      |> assign(:community_stats, %{members: 0, posts: 0})
      |> assign(:is_following_community, false)
      |> assign(:is_pending_community, false)
      |> assign(:replies, [])
      |> assign(:threaded_replies, [])
      |> assign(:thread_reply_actors, %{})
      |> assign(:replies_loading, false)
      |> assign(:replies_loaded, false)
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
      |> assign(:meta_description, nil)
      |> assign(:og_image, nil)
      |> assign(:submitted_link_preview, nil)
      |> assign(
        :current_url,
        ElektrineWeb.Endpoint.url() <> "/remote/post/" <> URI.encode_www_form(decoded_post_id)
      )

    # For initial render (not connected), do a quick synchronous fetch for SEO/link previews
    # This ensures meta tags are present in the initial HTML for crawlers
    socket =
      if connected?(socket) do
        socket
      else
        fetch_post_for_meta_tags(socket, decoded_post_id, is_local_post)
      end

    # Try to show cached local message immediately to prevent flicker
    socket =
      if is_local_post do
        socket
      else
        case Elektrine.Messaging.get_message_by_activitypub_id(decoded_post_id) do
          %{} = msg ->
            msg = preload_cached_message_associations(msg)

            cached_is_community = PostUtilities.community_post?(msg)

            # Build post object from cached message
            post_object = build_post_object_from_message(msg)

            socket
            |> assign(:local_message, msg)
            |> assign(:post, post_object)
            |> assign(:remote_actor, msg.remote_actor)
            |> assign(:is_community_post, socket.assigns.is_community_post || cached_is_community)
            |> assign(:replies_loading, true)
            |> assign(:loading, false)
            |> assign(
              :page_title,
              msg.title || "Post by @#{(msg.remote_actor && msg.remote_actor.username) || "user"}"
            )
            |> assign_reply_parent_fallback(post_object, msg)
            |> ensure_submitted_link_preview(
              post_object,
              msg,
              msg.remote_actor && msg.remote_actor.domain
            )

          nil ->
            socket
        end
      end

    # Defer full HTTP fetching to handle_info for interactive use
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "timeline:public")

      if is_local_post do
        send(self(), {:load_local_post, String.to_integer(decoded_post_id)})
      else
        # For cached content, check if it's a community post that needs community loaded
        cached_msg = socket.assigns[:local_message]

        if cached_msg do
          # Check if it's a community/Lemmy-like post that needs community loaded
          # Patterns: /post/ (Lemmy), /c/.../p/ (PieFed), or any post with Page type
          # Always try to load community for federated posts - it will be nil if none exists
          cached_community_uri = community_uri_from_local_message(cached_msg)

          if PostUtilities.community_post?(cached_msg) || is_binary(cached_community_uri) do
            send(self(), {:load_community_for_cached, decoded_post_id, cached_community_uri})
          end

          # Load main post interactions immediately for cached posts
          send(self(), {:load_main_post_interactions, cached_msg})

          # Load replies and counts for cached posts
          send(self(), {:load_replies_for_cached, cached_msg})
          send(self(), {:load_platform_counts, decoded_post_id})
          send(self(), {:load_reactions, decoded_post_id})
          send(self(), {:load_reply_parent, socket.assigns.post})
        else
          # No cached content - do full remote fetch
          send(self(), {:load_remote_post, decoded_post_id})
        end
      end
    end

    {:ok, socket}
  end

  # Check if a URL looks like a community/Lemmy-like post
  # Patterns: /post/ (Lemmy), /c/.../p/ (PieFed), /m/.../p/ (Mbin)
  defp community_post_url?(url) when is_binary(url) do
    LemmyApi.community_post_url?(url)
  end

  defp community_post_url?(_), do: false

  defp community_uri_from_local_message(%{media_metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "community_actor_uri") || Map.get(metadata, :community_actor_uri) do
      uri when is_binary(uri) ->
        case String.trim(uri) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp community_uri_from_local_message(_), do: nil

  # Find community URI from post object - check multiple possible fields
  # Different platforms use different fields for the community
  defp find_community_uri(post_object) do
    cond do
      # Standard Lemmy field
      is_binary(post_object["audience"]) ->
        post_object["audience"]

      # Some platforms put community in 'to' array (check for Group/community URI pattern)
      is_list(post_object["to"]) ->
        Enum.find(post_object["to"], fn uri ->
          is_binary(uri) && (String.contains?(uri, "/c/") || String.contains?(uri, "/m/"))
        end)

      # Check context field (some platforms use this)
      is_binary(post_object["context"]) && String.contains?(post_object["context"], "/c/") ->
        post_object["context"]

      true ->
        nil
    end
  end

  # Build an ActivityPub-like post object from a local message
  defp build_post_object_from_message(msg) do
    poll_fields = build_poll_fields_from_message(msg)
    reply_count = cached_reply_count(msg)
    submitted_link = message_submitted_link(msg)
    post_url = submitted_link || msg.activitypub_url || msg.activitypub_id
    metadata = msg.media_metadata || %{}
    in_reply_to = message_in_reply_to(msg)

    attachments =
      if msg.media_urls && msg.media_urls != [] do
        Enum.map(msg.media_urls, fn url ->
          full_url = Elektrine.Uploads.attachment_url(url)
          %{"type" => "Image", "url" => full_url, "mediaType" => "image/jpeg"}
        end)
      else
        []
      end

    %{
      "id" => msg.activitypub_id,
      "type" =>
        metadata["type"] ||
          if(community_post_url?(msg.activitypub_id || post_url || ""), do: "Page", else: "Note"),
      "url" => post_url,
      "content" => msg.content,
      "published" => NaiveDateTime.to_iso8601(msg.inserted_at) <> "Z",
      "attributedTo" => msg.remote_actor && msg.remote_actor.uri,
      "inReplyTo" => in_reply_to,
      "inReplyToAuthor" => metadata["inReplyToAuthor"],
      "inReplyToContent" => metadata["inReplyToContent"],
      "inReplyToTitle" => metadata["inReplyToTitle"],
      "attachment" => attachments,
      "name" => msg.title,
      "likes" => %{"totalItems" => msg.like_count || 0},
      "repliesCount" => reply_count,
      "replies" => %{"totalItems" => reply_count},
      "_cached" => true,
      "_local_message" => msg
    }
    |> Map.merge(poll_fields)
  end

  defp message_submitted_link(msg) do
    metadata = msg.media_metadata || %{}
    link_preview_url = message_link_preview_url(msg)
    message_id = msg.activitypub_id
    message_url = msg.activitypub_url

    [
      msg.primary_url,
      metadata["external_link"],
      metadata["url"],
      metadata["source_url"],
      metadata["canonical_url"],
      metadata["link_url"],
      metadata["link"],
      link_preview_url,
      extract_http_url_from_content(msg.content)
    ]
    |> Enum.map(&normalize_http_url/1)
    |> Enum.find(fn url ->
      is_binary(url) && url != message_id && url != message_url
    end)
  end

  defp message_link_preview_url(%{
         link_preview: %Elektrine.Social.LinkPreview{status: "success", url: url}
       })
       when is_binary(url),
       do: url

  defp message_link_preview_url(_), do: nil

  defp detect_submitted_url(post, local_message, remote_actor_domain)
       when is_map(post) do
    post_id = map_get_value(post, "id")

    [
      extract_attachment_submitted_link(map_get_value(post, "attachment")),
      extract_source_submitted_link(map_get_value(post, "source")),
      extract_url_field_submitted_link(map_get_value(post, "url"), post_id, remote_actor_domain),
      if(local_message, do: message_submitted_link(local_message), else: nil),
      extract_http_url_from_content(map_get_value(post, "content"))
    ]
    |> Enum.map(&normalize_http_url/1)
    |> Enum.find(&valid_submitted_url?(&1, post_id))
  end

  defp detect_submitted_url(_, _, _), do: nil

  defp submitted_url_host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp submitted_url_host(_), do: nil

  defp effective_link_preview(local_message, submitted_link_preview) do
    cond do
      match?(%{link_preview: %Elektrine.Social.LinkPreview{status: "success"}}, local_message) ->
        local_message.link_preview

      match?(%Elektrine.Social.LinkPreview{status: "success"}, submitted_link_preview) ->
        submitted_link_preview

      true ->
        nil
    end
  end

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
    if match?(%{link_preview: %Elektrine.Social.LinkPreview{status: "success"}}, local_message) do
      assign(socket, :submitted_link_preview, nil)
    else
      case detect_submitted_url(post_object, local_message, remote_actor_domain) do
        url when is_binary(url) ->
          case Elektrine.Repo.get_by(Elektrine.Social.LinkPreview, url: url) do
            %Elektrine.Social.LinkPreview{status: "success"} = preview ->
              assign(socket, :submitted_link_preview, preview)

            _ ->
              maybe_enqueue_submitted_link_preview(url, local_message)
              maybe_schedule_submitted_preview_poll(socket, url)
              assign(socket, :submitted_link_preview, nil)
          end

        _ ->
          assign(socket, :submitted_link_preview, nil)
      end
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

  defp maybe_enqueue_submitted_link_preview(_, _), do: :ok

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

  defp maybe_schedule_submitted_preview_poll(_, _), do: :ok

  defp current_submitted_url(socket) do
    detect_submitted_url(
      socket.assigns[:post],
      socket.assigns[:local_message],
      socket.assigns[:remote_actor] && socket.assigns.remote_actor.domain
    )
  end

  defp extract_youtube_id(url) when is_binary(url) do
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

  defp extract_youtube_id(_), do: nil

  defp quote_message_path(%{activitypub_id: activitypub_id})
       when is_binary(activitypub_id) and activitypub_id != "" do
    "/remote/post/#{URI.encode_www_form(activitypub_id)}"
  end

  defp quote_message_path(%{id: id}) when is_integer(id), do: "/remote/post/#{id}"

  defp quote_message_path(%{id: id}) when is_binary(id) and id != "" do
    "/remote/post/#{URI.encode_www_form(id)}"
  end

  defp quote_message_path(_), do: nil

  defp valid_submitted_url?(url, post_id) when is_binary(url) do
    url != post_id && String.starts_with?(url, ["http://", "https://"])
  end

  defp valid_submitted_url?(_, _), do: false

  defp extract_attachment_submitted_link(attachments) do
    attachments
    |> normalize_attachment_list()
    |> Enum.find_value(fn attachment ->
      type = map_get_value(attachment, "type")
      media_type = map_get_value(attachment, "mediaType")
      attachment_url = attachment_url(attachment)

      cond do
        !is_binary(attachment_url) ->
          nil

        type == "Link" ->
          attachment_url

        is_binary(media_type) && String.starts_with?(String.downcase(media_type), "text/html") ->
          attachment_url

        true ->
          nil
      end
    end)
  end

  defp extract_source_submitted_link(source) when is_map(source) do
    [map_get_value(source, "url"), map_get_value(source, "href")]
    |> Enum.map(&normalize_http_url/1)
    |> Enum.find(&is_binary/1)
  end

  defp extract_source_submitted_link(_), do: nil

  defp extract_url_field_submitted_link(url_field, post_id, remote_actor_domain) do
    urls =
      url_field
      |> url_candidates_from_field()
      |> Enum.map(&normalize_http_url/1)
      |> Enum.filter(fn url -> is_binary(url) && url != post_id end)

    Enum.find(urls, fn url ->
      case URI.parse(url) do
        %URI{host: host} when is_binary(host) and is_binary(remote_actor_domain) ->
          host != remote_actor_domain

        _ ->
          false
      end
    end) || List.first(urls)
  end

  defp normalize_attachment_list(nil), do: []
  defp normalize_attachment_list(attachments) when is_list(attachments), do: attachments
  defp normalize_attachment_list(attachment) when is_map(attachment), do: [attachment]
  defp normalize_attachment_list(_), do: []

  defp url_candidates_from_field(nil), do: []
  defp url_candidates_from_field(url) when is_binary(url), do: [url]

  defp url_candidates_from_field(urls) when is_list(urls) do
    Enum.flat_map(urls, &url_candidates_from_field/1)
  end

  defp url_candidates_from_field(url_map) when is_map(url_map) do
    [
      map_get_value(url_map, "href"),
      map_get_value(url_map, "url"),
      map_get_value(url_map, "id")
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp url_candidates_from_field(_), do: []

  defp attachment_url(attachment) when is_map(attachment) do
    case map_get_value(attachment, "url") do
      url when is_binary(url) ->
        url

      url_map when is_map(url_map) ->
        map_get_value(url_map, "href") || map_get_value(url_map, "url")

      url_list when is_list(url_list) ->
        url_list
        |> Enum.flat_map(&url_candidates_from_field/1)
        |> List.first()

      _ ->
        map_get_value(attachment, "href")
    end
  end

  defp attachment_url(_), do: nil

  defp map_get_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {k, value} when is_atom(k) ->
            if Atom.to_string(k) == key, do: value, else: nil

          _ ->
            nil
        end)
    end
  end

  defp map_get_value(_, _), do: nil

  defp normalize_http_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    if String.starts_with?(trimmed, ["http://", "https://"]) do
      trimmed
    else
      nil
    end
  end

  defp normalize_http_url(_), do: nil

  defp extract_http_url_from_content(content) when is_binary(content) do
    with [_, href] <- Regex.run(~r/href=["']([^"']+)["']/i, content),
         normalized when is_binary(normalized) <- normalize_http_url(href) do
      normalized
    else
      _ ->
        case Regex.run(~r/https?:\/\/[^\s<>"']+/i, content) do
          [url] -> normalize_http_url(url)
          _ -> nil
        end
    end
  end

  defp extract_http_url_from_content(_), do: nil

  defp maybe_preserve_cached_post_fields(post_object, existing_post) do
    post_object
    |> maybe_put_field_from_existing(existing_post, "content")
    |> maybe_put_field_from_existing(existing_post, "name")
    |> maybe_put_field_from_existing(existing_post, "inReplyTo")
    |> maybe_put_field_from_existing(existing_post, "inReplyToAuthor")
    |> maybe_put_field_from_existing(existing_post, "inReplyToContent")
    |> maybe_put_field_from_existing(existing_post, "inReplyToTitle")
  end

  defp maybe_put_field_from_existing(post_object, existing_post, key) do
    current = map_get_value(post_object, key)
    fallback = map_get_value(existing_post, key)

    if is_binary(current) && String.trim(current) != "" do
      post_object
    else
      if is_binary(fallback) && String.trim(fallback) != "" do
        Map.put(post_object, key, fallback)
      else
        post_object
      end
    end
  end

  defp preload_cached_message_associations(message) do
    Elektrine.Repo.preload(message, Elektrine.Messaging.Messages.timeline_post_preloads())
  end

  defp message_in_reply_to(message) when is_map(message) do
    metadata = local_message_metadata(message)

    [metadata["inReplyTo"], metadata["in_reply_to"], message_reply_parent(message)]
    |> Enum.find_value(&normalize_in_reply_to_ref/1)
  end

  defp message_in_reply_to(_), do: nil

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

  defp ancestor_post_ref(parent_post, in_reply_to_ref) do
    [
      map_get_value(parent_post, "id"),
      in_reply_to_ref,
      map_get_value(parent_post, "url")
    ]
    |> Enum.find_value(&normalize_in_reply_to_ref/1)
  end

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
    case Messaging.get_message_by_activitypub_ref(in_reply_to) do
      %{} = parent_message ->
        parent_message = preload_cached_message_associations(parent_message)
        {:ok, build_reply_parent_from_message(parent_message), parent_message.remote_actor}

      _ ->
        :error
    end
  end

  defp local_reply_parent_from_ref(_), do: :error

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
          if(community_post_url?(message.activitypub_id || message.activitypub_url || ""),
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
      "_local_like_count" => message.like_count || 0,
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
      case Messaging.get_message_by_activitypub_ref(ref) do
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
        case ActivityPub.Fetcher.fetch_object(in_reply_to) do
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

  defp parent_post_in_reply_to_ref(_), do: nil

  defp maybe_fetch_reply_parent_actor(parent_post) when is_map(parent_post) do
    attributed_to = extract_attributed_to_uri(parent_post)

    cond do
      !is_binary(attributed_to) ->
        nil

      local_actor_uri?(attributed_to) ->
        nil

      true ->
        case ActivityPub.get_or_fetch_actor(attributed_to) do
          {:ok, actor} -> actor
          _ -> nil
        end
    end
  end

  defp maybe_fetch_reply_parent_actor(_), do: nil

  defp extract_attributed_to_uri(post) when is_map(post) do
    post
    |> map_get_value("attributedTo")
    |> normalize_in_reply_to_ref()
  end

  defp extract_attributed_to_uri(_), do: nil

  defp local_actor_uri?(uri) when is_binary(uri) do
    ActivityPub.local_actor_prefixes()
    |> Enum.any?(fn prefix -> String.starts_with?(uri, prefix) end)
  end

  defp local_actor_uri?(_), do: false

  defp reply_parent_author_label(reply_parent, reply_parent_actor) do
    cond do
      reply_parent_actor && is_binary(reply_parent_actor.username) &&
          is_binary(reply_parent_actor.domain) ->
        "@#{reply_parent_actor.username}@#{reply_parent_actor.domain}"

      is_map(reply_parent) && is_map(reply_parent["_local_user"]) ->
        local_user = reply_parent["_local_user"]

        "@#{local_user.handle || local_user.username}@#{Elektrine.Domains.default_user_handle_domain()}"

      is_map(reply_parent) && is_binary(reply_parent["_fallback_author"]) ->
        reply_parent["_fallback_author"]

      is_map(reply_parent) && is_binary(reply_parent["attributedTo"]) ->
        "@#{SurfaceHelpers.extract_username_from_uri(reply_parent["attributedTo"])}"

      true ->
        "original post"
    end
  end

  defp reply_parent_content_domain(reply_parent, reply_parent_actor, in_reply_to) do
    cond do
      reply_parent_actor && is_binary(reply_parent_actor.domain) ->
        reply_parent_actor.domain

      is_map(reply_parent) && is_binary(reply_parent["attributedTo"]) ->
        case URI.parse(reply_parent["attributedTo"]) do
          %URI{host: host} when is_binary(host) and host != "" -> host
          _ -> nil
        end

      is_binary(in_reply_to) ->
        case URI.parse(in_reply_to) do
          %URI{host: host} when is_binary(host) and host != "" -> host
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp http_url?(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.starts_with?(["http://", "https://"])
  end

  defp http_url?(_), do: false

  defp build_poll_fields_from_message(nil), do: %{}

  defp build_poll_fields_from_message(message) do
    cond do
      message.post_type != "poll" ->
        %{}

      !Ecto.assoc_loaded?(message.poll) || is_nil(message.poll) ->
        %{}

      true ->
        poll = message.poll

        options =
          if Ecto.assoc_loaded?(poll.options) do
            Enum.map(poll.options, fn option ->
              %{
                "type" => "Note",
                "name" => option.option_text,
                "replies" => %{
                  "type" => "Collection",
                  "totalItems" => option.vote_count || 0
                }
              }
            end)
          else
            []
          end

        if options == [] do
          %{}
        else
          poll_key = if poll.allow_multiple, do: "anyOf", else: "oneOf"

          %{
            "type" => "Question",
            poll_key => options,
            "votersCount" => poll.voters_count || poll.total_votes || 0
          }
          |> maybe_add_poll_close_time(poll.closes_at)
        end
    end
  end

  defp maybe_add_poll_close_time(poll_fields, %DateTime{} = closes_at) do
    timestamp = DateTime.to_iso8601(closes_at)

    poll_fields
    |> Map.put("endTime", timestamp)
    |> Map.put("closed", timestamp)
  end

  defp maybe_add_poll_close_time(poll_fields, %NaiveDateTime{} = closes_at) do
    timestamp = closes_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

    poll_fields
    |> Map.put("endTime", timestamp)
    |> Map.put("closed", timestamp)
  end

  defp maybe_add_poll_close_time(poll_fields, _), do: poll_fields

  defp post_has_poll_data?(post_object) when is_map(post_object) do
    post_object["type"] == "Question" ||
      is_list(post_object["oneOf"]) ||
      is_list(post_object["anyOf"])
  end

  defp post_has_poll_data?(_), do: false

  defp merge_local_poll_data(post_object, local_message) do
    if post_has_poll_data?(post_object) do
      post_object
    else
      Map.merge(post_object, build_poll_fields_from_message(local_message))
    end
  end

  # Quick synchronous fetch for SEO meta tags (only on initial render)
  defp fetch_post_for_meta_tags(socket, post_id, true = _is_local) do
    # Local post - quick database lookup
    import Ecto.Query

    case Elektrine.Messaging.Message
         |> where([m], m.id == ^String.to_integer(post_id))
         |> Elektrine.Repo.one()
         |> Elektrine.Repo.preload([:sender]) do
      nil ->
        socket

      message ->
        # Build meta tags from local message
        description = build_og_description(message.content)
        image = get_first_media_url(message.media_urls)

        sender_username =
          case message.sender do
            %{username: username} when is_binary(username) and username != "" -> username
            _ -> "unknown"
          end

        title = message.title || "Post by #{sender_username}"

        socket
        |> assign(:page_title, title)
        |> assign(:meta_description, description)
        |> assign(:og_image, image)
    end
  end

  defp fetch_post_for_meta_tags(socket, post_id, false = _is_local) do
    # Remote post - try cache first, then quick fetch with timeout
    # First check if we have it cached locally
    case Elektrine.Messaging.get_message_by_activitypub_id(post_id) do
      %{} = msg ->
        # Preload associations for actor info
        msg = Elektrine.Repo.preload(msg, [:remote_actor, :sender])

        # We have it cached locally
        description = build_og_description(msg.content)
        image = get_first_media_url(msg.media_urls)

        # Try to get actor info
        actor_name =
          cond do
            msg.remote_actor && msg.remote_actor.username ->
              "@#{msg.remote_actor.username}@#{msg.remote_actor.domain}"

            msg.sender && msg.sender.username ->
              "@#{msg.sender.username}"

            true ->
              nil
          end

        page_title = msg.title || (actor_name && "Post by #{actor_name}") || "Remote Post"

        socket
        |> assign(:page_title, page_title)
        |> assign(:meta_description, description)
        |> assign(:og_image, image)

      nil ->
        # Not cached - do a quick fetch with short timeout for SEO
        # Use Task.yield with 3 second timeout to avoid blocking too long
        task =
          Task.async(fn ->
            ActivityPub.Fetcher.fetch_object(post_id)
          end)

        case Task.yield(task, 3_000) || Task.shutdown(task) do
          {:ok, {:ok, post_object}} ->
            # Extract meta info from ActivityPub object
            content = post_object["content"] || post_object["summary"] || ""
            description = build_og_description(content)

            # Get first image from attachments
            image =
              case post_object["attachment"] do
                [%{"url" => url} | _] when is_binary(url) -> url
                [%{"url" => [%{"href" => url} | _]} | _] when is_binary(url) -> url
                _ -> nil
              end

            # Build actor name from URI without extra DB lookup
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

          _ ->
            # Timeout or error - just use defaults
            socket
        end
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
  defp get_first_media_url(nil), do: nil
  defp get_first_media_url([]), do: nil

  defp get_first_media_url(urls) when is_list(urls) do
    Enum.find_value(urls, fn
      url when is_binary(url) and url != "" ->
        full_url = Elektrine.Uploads.attachment_url(url)

        if is_binary(full_url) && String.match?(full_url, ~r/\.(jpe?g|png|gif|webp|svg)(\?.*)?$/i) do
          full_url
        else
          nil
        end

      _ ->
        nil
    end)
  end

  defp get_first_media_url(_), do: nil

  @impl true
  def handle_info({:load_local_post, message_id}, socket) do
    # Load local message from database
    import Ecto.Query

    message =
      Elektrine.Messaging.Message
      |> where([m], m.id == ^message_id)
      |> Elektrine.Repo.one()
      |> Elektrine.Repo.preload(
        Elektrine.Messaging.Messages.timeline_post_preloads() ++
          [replies: [sender: [:profile], remote_actor: []]]
      )

    if message do
      # Convert local message to ActivityPub-like format for the template
      sender = message.sender
      base_url = ElektrineWeb.Endpoint.url()

      # Build image attachments
      attachments =
        if message.media_urls && message.media_urls != [] do
          message.media_urls
          |> Enum.filter(&(is_binary(&1) && &1 != ""))
          |> Enum.map(fn url ->
            full_url = Elektrine.Uploads.attachment_url(url)

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

      # Convert replies to ActivityPub-like format
      local_replies =
        Enum.map(message.replies || [], fn reply ->
          {actor_uri, local_user, is_local_reply} =
            cond do
              reply.sender && is_binary(reply.sender.username) && reply.sender.username != "" ->
                {"#{base_url}/users/#{reply.sender.username}", reply.sender, true}

              reply.remote_actor && is_binary(reply.remote_actor.uri) &&
                  reply.remote_actor.uri != "" ->
                {reply.remote_actor.uri, nil, false}

              reply.remote_actor && is_binary(reply.remote_actor.domain) &&
                is_binary(reply.remote_actor.username) && reply.remote_actor.domain != "" &&
                  reply.remote_actor.username != "" ->
                {"https://#{reply.remote_actor.domain}/users/#{reply.remote_actor.username}", nil,
                 false}

              true ->
                {nil, nil, false}
            end

          %{
            "id" => reply.activitypub_id || "#{base_url}/posts/#{reply.id}",
            "type" => "Note",
            "content" => reply.content,
            "published" => NaiveDateTime.to_iso8601(reply.inserted_at) <> "Z",
            "attributedTo" => actor_uri,
            "inReplyTo" =>
              Map.get(reply, :parent_activitypub_id) || "#{base_url}/posts/#{message.id}",
            "_local" => is_local_reply,
            "_local_user" => local_user,
            "_local_message_id" => reply.id
          }
        end)

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
        from(r in Elektrine.Messaging.MessageReaction,
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
          user_id = socket.assigns.current_user.id

          post_state = %{
            liked: Social.user_liked_post?(user_id, message.id),
            boosted: Social.user_boosted?(user_id, message.id),
            like_delta: 0,
            boost_delta: 0
          }

          {
            Map.put(socket.assigns.post_interactions, local_post_key, post_state),
            Map.put(
              socket.assigns.user_saves,
              local_post_key,
              Social.post_saved?(user_id, message.id)
            )
          }
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

      send(self(), {:load_reply_parent, post_object})

      {:noreply, updated_socket}
    else
      {:noreply,
       socket
       |> assign(:loading, false)
       |> assign(:load_error, "Post not found")}
    end
  end

  @impl true
  def handle_info({:load_remote_post, post_id}, socket) do
    # Run all HTTP fetches in a Task to avoid blocking the LiveView process
    task =
      Task.async(fn ->
        case ActivityPub.Fetcher.fetch_object(post_id) do
          {:ok, post_object} ->
            author_uri = post_object["attributedTo"]

            remote_actor =
              case ActivityPub.get_or_fetch_actor(author_uri) do
                {:ok, actor} -> actor
                _ -> nil
              end

            if remote_actor do
              # Fetch community actor if present
              # Check multiple possible fields for community URI
              community_uri = find_community_uri(post_object)

              community_actor =
                if community_uri do
                  case ActivityPub.get_or_fetch_actor(community_uri) do
                    {:ok, actor} -> actor
                    _ -> nil
                  end
                else
                  nil
                end

              {:ok, %{post: post_object, actor: remote_actor, community: community_actor}}
            else
              {:error, :actor_not_found}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end)

    # Wait with timeout - don't block forever
    case Task.yield(task, 15_000) || Task.shutdown(task) do
      {:ok, {:ok, %{post: post_object, actor: remote_actor, community: community_actor}}} ->
        # Load local message if it exists (used for interactions and poll fallback data)
        local_message =
          post_object["id"]
          |> Elektrine.Messaging.get_message_by_activitypub_id()
          |> case do
            nil -> nil
            message -> preload_cached_message_associations(message)
          end

        post_object = merge_local_poll_data(post_object, local_message)
        local_community_uri = community_uri_from_local_message(local_message)

        community_actor =
          cond do
            community_actor ->
              community_actor

            is_binary(local_community_uri) ->
              case ActivityPub.get_or_fetch_actor(local_community_uri) do
                {:ok, actor} -> actor
                _ -> nil
              end

            true ->
              nil
          end

        is_community_post =
          !is_nil(community_actor) ||
            is_binary(find_community_uri(post_object)) ||
            is_binary(local_community_uri) ||
            community_post_url?(post_object["id"] || "") ||
            community_post_url?(post_object["url"] || "")

        # Check if user follows the community (accepted or pending)
        {is_following_community, is_pending_community} =
          if socket.assigns[:current_user] && community_actor do
            # Check for accepted follow first
            if Elektrine.Profiles.following_remote_actor?(
                 socket.assigns.current_user.id,
                 community_actor.id
               ) do
              {true, false}
            else
              # Check for pending follow
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

        # Subscribe to user's timeline for follow acceptance updates
        if socket.assigns[:current_user] && community_actor do
          Phoenix.PubSub.subscribe(
            Elektrine.PubSub,
            "user:#{socket.assigns.current_user.id}:timeline"
          )
        end

        # Update socket with post data, then defer replies loading
        socket =
          socket
          |> assign(:loading, false)
          |> assign(:replies_loading, true)
          |> assign(
            :page_title,
            post_object["name"] || "Post by @#{remote_actor.username}@#{remote_actor.domain}"
          )
          |> assign(:post, post_object)
          |> assign(:remote_actor, remote_actor)
          |> assign(:community_actor, community_actor)
          |> assign(:community_stats, initial_community_stats(community_actor))
          |> assign(:is_community_post, is_community_post)
          |> assign(:is_following_community, is_following_community)
          |> assign(:is_pending_community, is_pending_community)

        # Update local message counts with fresh data from source (async)
        Task.start(fn -> Elektrine.Messaging.Messages.sync_remote_counts(post_object) end)

        socket =
          socket
          |> assign(:local_message, local_message)
          |> assign_reply_parent_fallback(post_object, local_message)
          |> ensure_submitted_link_preview(post_object, local_message, remote_actor.domain)

        # Load main post interactions immediately
        socket =
          if socket.assigns[:current_user] do
            interactions = load_post_interactions([post_object], socket.assigns.current_user.id)
            assign(socket, :post_interactions, interactions)
          else
            socket
          end

        # Defer replies and platform-specific counts loading
        send(self(), {:load_reply_parent, post_object})
        send(self(), {:load_replies, post_object})
        send(self(), {:load_platform_counts, post_object["id"]})
        send(self(), {:load_reactions, post_object["id"]})

        if community_actor && community_actor.actor_type == "Group" do
          send(self(), :load_community_stats)
        end

        # Schedule background refresh worker for this post if it has a local copy
        if local_message do
          Elektrine.ActivityPub.RefreshCountsWorker.schedule_single_refresh(local_message.id)
        end

        {:noreply, socket}

      {:ok, {:error, _reason}} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:load_error, "Failed to load remote post")
         |> put_flash(:error, "Failed to load remote post")}

      nil ->
        # Timeout
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:load_error, "Remote server took too long to respond")
         |> put_flash(:error, "Remote server took too long to respond")}
    end
  end

  def handle_info({:load_community_for_cached, post_id}, socket) do
    fallback_community_uri = community_uri_from_local_message(socket.assigns[:local_message])
    handle_info({:load_community_for_cached, post_id, fallback_community_uri}, socket)
  end

  # Load community actor for cached community posts
  def handle_info({:load_community_for_cached, post_id, fallback_community_uri}, socket) do
    liveview_pid = self()

    Task.start(fn ->
      # Fetch the post to get the community URI from various fields
      case ActivityPub.Fetcher.fetch_object(post_id) do
        {:ok, post_object} ->
          send(liveview_pid, {:cached_post_object_loaded, post_object})

          community_uri = find_community_uri(post_object) || fallback_community_uri

          if community_uri do
            send(liveview_pid, :community_detected)

            case ActivityPub.get_or_fetch_actor(community_uri) do
              {:ok, community_actor} ->
                send(liveview_pid, {:community_loaded, community_actor})

              _ ->
                :ok
            end
          end

        _ ->
          if is_binary(fallback_community_uri) do
            send(liveview_pid, :community_detected)

            case ActivityPub.get_or_fetch_actor(fallback_community_uri) do
              {:ok, community_actor} ->
                send(liveview_pid, {:community_loaded, community_actor})

              _ ->
                :ok
            end
          end
      end
    end)

    {:noreply, socket}
  end

  def handle_info(:community_detected, socket) do
    {:noreply, assign(socket, :is_community_post, true)}
  end

  def handle_info({:cached_post_object_loaded, post_object}, socket) do
    local_message = socket.assigns[:local_message]
    existing_post = socket.assigns[:post] || %{}

    post_object =
      post_object
      |> merge_local_poll_data(local_message)
      |> maybe_preserve_cached_post_fields(existing_post)

    is_community_post =
      socket.assigns.is_community_post ||
        is_binary(find_community_uri(post_object)) ||
        is_binary(community_uri_from_local_message(local_message)) ||
        community_post_url?(post_object["id"] || "") ||
        community_post_url?(post_object["url"] || "")

    updated_socket =
      socket
      |> assign(:post, post_object)
      |> assign(:is_community_post, is_community_post)
      |> assign(:page_title, post_object["name"] || socket.assigns.page_title)
      |> assign_reply_parent_fallback(post_object, local_message)
      |> ensure_submitted_link_preview(
        post_object,
        local_message,
        socket.assigns[:remote_actor] && socket.assigns.remote_actor.domain
      )

    send(self(), {:load_reply_parent, post_object})

    {:noreply, updated_socket}
  end

  # Handle community actor loaded for cached posts
  def handle_info({:community_loaded, community_actor}, socket) do
    # Check follow status for community
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

    {:noreply,
     socket
     |> assign(:community_actor, community_actor)
     |> assign(:community_stats, initial_community_stats(community_actor))
     |> assign(:is_community_post, true)
     |> assign(:is_following_community, is_following_community)
     |> assign(:is_pending_community, is_pending_community)}
  end

  def handle_info(:load_community_stats, socket) do
    case socket.assigns.community_actor do
      %{actor_type: "Group"} = community_actor ->
        pid = self()

        Task.start(fn ->
          stats = fetch_group_stats(community_actor)
          send(pid, {:community_stats_loaded, stats})
        end)

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:community_stats_loaded, %{} = stats}, socket) do
    current = socket.assigns[:community_stats] || %{members: 0, posts: 0}

    merged_stats = %{
      members: max(current[:members] || 0, stats[:members] || 0),
      posts: max(current[:posts] || 0, stats[:posts] || 0)
    }

    {:noreply, assign(socket, :community_stats, merged_stats)}
  end

  # Load replies for cached posts
  def handle_info({:load_replies_for_cached, msg}, socket) do
    post_id = msg.activitypub_id || msg.activitypub_url
    post_url = msg.activitypub_url || post_id
    replies_count = cached_reply_count(msg)
    replies_object = cached_replies_object(msg, replies_count)
    comments_object = cached_comments_object(msg, replies_count)

    is_community_post = PostUtilities.community_post?(msg)

    # Build a post object from the cached message for reply fetching.
    # Include URL/count metadata so fallback fetchers (context APIs) run when needed.
    post_object = %{
      "id" => post_id,
      "url" => post_url,
      "type" => if(is_community_post, do: "Page", else: "Note"),
      "repliesCount" => replies_count,
      "replies" => replies_object,
      "comments" => comments_object
    }

    if is_binary(post_id) do
      send(self(), {:load_replies, post_object})
    end

    {:noreply,
     socket
     |> assign(:replies_loading, is_binary(post_id))
     |> assign(:is_community_post, socket.assigns.is_community_post || is_community_post)}
  end

  # Load interactions for the main post immediately (for cached posts)
  def handle_info({:load_main_post_interactions, msg}, socket) do
    if socket.assigns[:current_user] && msg.activitypub_id do
      # Build a minimal post object for load_post_interactions
      post_object = %{"id" => msg.activitypub_id}
      interactions = load_post_interactions([post_object], socket.assigns.current_user.id)

      # Merge with existing post_interactions (don't overwrite reply interactions)
      updated_interactions = Map.merge(socket.assigns.post_interactions, interactions)
      {:noreply, assign(socket, :post_interactions, updated_interactions)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:load_reply_parent, post_object}, socket) when is_map(post_object) do
    local_message = socket.assigns[:local_message]
    in_reply_to = extract_post_in_reply_to(post_object, local_message)
    socket = assign_reply_parent_fallback(socket, post_object, local_message)
    socket = hydrate_ancestor_surface_data(socket, socket.assigns.reply_ancestors)

    if is_binary(in_reply_to) do
      liveview_pid = self()

      Task.start(fn ->
        result = resolve_reply_ancestor_chain(in_reply_to)
        send(liveview_pid, {:reply_ancestors_loaded, in_reply_to, result})
      end)
    end

    {:noreply, socket}
  end

  def handle_info({:load_reply_parent, _}, socket), do: {:noreply, socket}

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
    # Capture the LiveView PID before starting the task
    liveview_pid = self()

    # Set loading state
    socket = assign(socket, :replies_loading, true)

    # Fetch replies in background
    Task.start(fn ->
      case ActivityPub.fetch_remote_post_replies(post_object, limit: 50) do
        {:ok, replies} ->
          send(liveview_pid, {:replies_loaded, replies, post_object["id"]})

        {:error, _} ->
          send(liveview_pid, {:replies_loaded, [], post_object["id"]})
      end
    end)

    # Proactively fetch and store replies from the collection (Akkoma-style)
    # This runs in parallel with the above fetch and stores replies locally
    if post_object["replies"] do
      Task.start(fn ->
        Elektrine.ActivityPub.RepliesFetcher.fetch_and_store_replies(post_object)
      end)
    end

    {:noreply, socket}
  end

  def handle_info({:replies_loaded, replies, post_id}, socket) do
    # Merge local replies with remote replies
    merged_replies = SurfaceHelpers.merge_local_replies(replies, post_id)

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

    # Cache reply authors in background (non-blocking)
    Task.start(fn ->
      merged_replies
      |> Enum.filter(fn reply -> reply["attributedTo"] && !reply["_local"] end)
      |> Task.async_stream(
        fn reply -> ActivityPub.get_or_fetch_actor(reply["attributedTo"]) end,
        max_concurrency: 10,
        timeout: 10_000,
        on_timeout: :kill_task
      )
      |> Stream.run()
    end)

    {:noreply,
     socket
     |> assign(:replies, merged_replies)
     |> assign(
       :quick_reply_recent_replies,
       SurfaceHelpers.recent_replies_for_preview(merged_replies, post_id)
     )
     |> assign(:threaded_replies, threaded_replies)
     |> assign(:thread_reply_actors, thread_reply_actors)
     |> assign(:replies_loading, false)
     |> assign(:replies_loaded, true)
     |> assign(:post_interactions, post_interactions)
     |> assign(:post_reactions, post_reactions)}
  end

  def handle_info({:load_platform_counts, post_id}, socket) do
    # Detect platform and fetch appropriate counts
    cond do
      # Lemmy/community posts - check for various URL patterns
      # /post/ (Lemmy), /c/.../p/ (PieFed), /m/.../p/ or /m/.../t/ (Mbin)
      community_post_url?(post_id) ->
        # Try to fetch Lemmy-style counts (works for Lemmy, may work for compatible platforms)
        lemmy_counts = Elektrine.ActivityPub.LemmyApi.fetch_post_counts(post_id)
        lemmy_comment_counts = Elektrine.ActivityPub.LemmyApi.fetch_comment_counts(post_id)

        {:noreply,
         socket
         |> assign(:lemmy_counts, lemmy_counts)
         |> assign(:lemmy_comment_counts, lemmy_comment_counts)
         |> assign(:mastodon_counts, nil)}

      # Mastodon-compatible posts
      Elektrine.ActivityPub.MastodonApi.mastodon_compatible?(%{activitypub_id: post_id}) ->
        mastodon_counts = Elektrine.ActivityPub.MastodonApi.fetch_status_counts(post_id)

        # Update local message counts if they're higher
        if mastodon_counts && socket.assigns[:local_message] do
          update_local_message_counts(socket.assigns.local_message, mastodon_counts)
        end

        {:noreply,
         socket
         |> assign(:mastodon_counts, mastodon_counts)
         |> assign(:lemmy_counts, nil)
         |> assign(:lemmy_comment_counts, nil)}

      # Other ActivityPub posts
      true ->
        {:noreply,
         socket
         |> assign(:mastodon_counts, nil)
         |> assign(:lemmy_counts, nil)
         |> assign(:lemmy_comment_counts, nil)}
    end
    |> then(fn {:noreply, socket} ->
      # Schedule periodic refresh every 60 seconds
      Process.send_after(self(), {:refresh_remote_counts, post_id}, 60_000)
      {:noreply, socket}
    end)
  end

  # Legacy handler for backwards compatibility
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
          from(r in Elektrine.Messaging.MessageReaction,
            where: r.message_id == ^message.id,
            preload: [:user, :remote_actor]
          )
          |> Elektrine.Repo.all()

        {:noreply,
         assign(
           socket,
           :post_reactions,
           Map.put(socket.assigns.post_reactions || %{}, activitypub_id, reactions)
         )}
    end
  end

  def handle_info({:refresh_remote_counts, post_id}, socket) do
    # Refresh Lemmy-specific counts
    lemmy_counts = Elektrine.ActivityPub.LemmyApi.fetch_post_counts(post_id)
    lemmy_comment_counts = Elektrine.ActivityPub.LemmyApi.fetch_comment_counts(post_id)

    # Also refresh the post object for non-Lemmy posts to get fresh counts
    socket =
      if socket.assigns.post && !community_post_url?(post_id) do
        case Elektrine.ActivityPub.Fetcher.fetch_object(post_id) do
          {:ok, fresh_post} ->
            # Update local database with fresh counts
            Task.start(fn -> Elektrine.Messaging.Messages.sync_remote_counts(fresh_post) end)

            # Update the post assign with fresh data (merge to preserve _mastodon data)
            updated_post = Map.merge(socket.assigns.post, fresh_post)
            assign(socket, :post, updated_post)

          _ ->
            socket
        end
      else
        socket
      end

    # Schedule next refresh (30 seconds for better responsiveness)
    Process.send_after(self(), {:refresh_remote_counts, post_id}, 30_000)

    {:noreply,
     socket
     |> assign(:lemmy_counts, lemmy_counts)
     |> assign(:lemmy_comment_counts, lemmy_comment_counts)}
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

      updated_post = apply_counts_to_post_object(socket.assigns[:post], counts)

      updated_modal_post =
        case socket.assigns[:modal_post] do
          %{"id" => _id} = post -> apply_counts_to_post_object(post, counts)
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

      {:noreply,
       socket
       |> assign(:local_message, updated_local_message)
       |> assign(:post, updated_post)
       |> assign(:modal_post, updated_modal_post)
       |> assign(:lemmy_counts, updated_lemmy_counts)
       |> assign(:mastodon_counts, updated_mastodon_counts)}
    else
      {:noreply, socket}
    end
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

  defp cached_reply_count(msg) do
    metadata = msg.media_metadata || %{}

    [
      normalize_cached_reply_count(msg.reply_count),
      normalize_cached_reply_count(metadata["original_reply_count"]),
      normalize_cached_reply_count(metadata["reply_count"]),
      normalize_cached_reply_count(metadata["replies_count"]),
      normalize_cached_reply_count(total_items_from_collection(metadata["replies"])),
      normalize_cached_reply_count(total_items_from_collection(metadata["comments"]))
    ]
    |> Enum.max(fn -> 0 end)
  end

  defp total_items_from_collection(collection) when is_map(collection) do
    Map.get(collection, "totalItems") || Map.get(collection, :totalItems)
  end

  defp total_items_from_collection(_), do: nil

  defp apply_counts_to_post_object(nil, _counts), do: nil

  defp apply_counts_to_post_object(post, counts) when is_map(post) do
    post
    |> Map.put("likes", put_collection_total(Map.get(post, "likes"), counts.like_count))
    |> Map.put("replies", put_collection_total(Map.get(post, "replies"), counts.reply_count))
    |> Map.put("shares", put_collection_total(Map.get(post, "shares"), counts.share_count))
    |> Map.put("like_count", counts.like_count)
    |> Map.put("reply_count", counts.reply_count)
    |> Map.put("share_count", counts.share_count)
  end

  defp put_collection_total(nil, total), do: %{"type" => "Collection", "totalItems" => total}

  defp put_collection_total(collection, total) when is_map(collection) do
    collection
    |> Map.put("totalItems", total)
    |> Map.put(:totalItems, total)
  end

  defp cached_replies_object(msg, replies_count) do
    metadata = msg.media_metadata || %{}

    cond do
      is_map(metadata["replies"]) ->
        Map.put_new(metadata["replies"], "totalItems", replies_count)

      is_binary(metadata["replies_url"]) ->
        %{"id" => metadata["replies_url"], "totalItems" => replies_count}

      replies_count > 0 ->
        %{"totalItems" => replies_count}

      true ->
        nil
    end
  end

  defp cached_comments_object(msg, replies_count) do
    metadata = msg.media_metadata || %{}

    cond do
      is_map(metadata["comments"]) ->
        Map.put_new(metadata["comments"], "totalItems", replies_count)

      is_binary(metadata["comments_url"]) ->
        %{"id" => metadata["comments_url"], "totalItems" => replies_count}

      true ->
        nil
    end
  end

  defp normalize_cached_reply_count(value) when is_integer(value), do: max(value, 0)

  defp normalize_cached_reply_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> max(parsed, 0)
      :error -> 0
    end
  end

  defp normalize_cached_reply_count(_), do: 0

  defp update_local_message_counts(local_message, %{
         favourites_count: fav,
         reblogs_count: reb,
         replies_count: rep
       }) do
    import Ecto.Query

    updates =
      []
      |> then(fn u ->
        if fav > (local_message.like_count || 0), do: [{:like_count, fav} | u], else: u
      end)
      |> then(fn u ->
        if reb > (local_message.share_count || 0), do: [{:share_count, reb} | u], else: u
      end)
      |> then(fn u ->
        if rep > (local_message.reply_count || 0), do: [{:reply_count, rep} | u], else: u
      end)

    if updates != [] do
      Elektrine.Repo.update_all(
        from(m in Elektrine.Messaging.Message, where: m.id == ^local_message.id),
        set: updates ++ [updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )
    end
  end

  defp update_local_message_counts(_, _), do: :ok

  @impl true
  def handle_event("toggle_reply_form", _params, socket) do
    {:noreply, assign(socket, :show_reply_form, !socket.assigns.show_reply_form)}
  end

  def handle_event("navigate_to_embedded_post", %{"id" => id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(navigate_id)}")}
  end

  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket)
      when is_binary(url) and url != "" and url != "#" do
    trimmed_url = String.trim(url)

    case URI.parse(trimmed_url) do
      %URI{scheme: nil, host: nil} ->
        {:noreply, push_navigate(socket, to: trimmed_url)}

      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(trimmed_url)}")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("navigate_to_embedded_post", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("navigate_to_post", %{"post_id" => post_id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, post_id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(navigate_id)}")}
  end

  def handle_event("navigate_to_post", %{"id" => id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(navigate_id)}")}
  end

  def handle_event("navigate_to_post", %{"message_id" => message_id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, message_id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(navigate_id)}")}
  end

  def handle_event("navigate_to_remote_post", %{"url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(url)}")}
  end

  def handle_event("navigate_to_remote_post", %{"id" => id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(navigate_id)}")}
  end

  def handle_event("navigate_to_remote_post", %{"post_id" => post_id}, socket) do
    navigate_id = normalize_navigate_post_id(socket, post_id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(navigate_id)}")}
  end

  def handle_event("navigate_to_remote_post", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_external_link", %{"url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, redirect(socket, external: url)}
  end

  def handle_event("open_external_link", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("navigate_to_profile", %{"handle" => handle}, socket)
      when is_binary(handle) and handle != "" do
    {:noreply, push_navigate(socket, to: "/#{handle}")}
  end

  def handle_event("navigate_to_profile", %{"username" => username}, socket)
      when is_binary(username) and username != "" do
    {:noreply, push_navigate(socket, to: "/#{username}")}
  end

  def handle_event("stop_propagation", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("toggle_comment_reply", %{"comment_id" => comment_id}, socket) do
    current = socket.assigns.replying_to_comment_id
    new_id = if current == comment_id, do: nil, else: comment_id

    {:noreply,
     socket
     |> assign(:replying_to_comment_id, new_id)
     |> assign(:comment_reply_content, "")}
  end

  def handle_event("update_comment_reply_content", %{"value" => content}, socket) do
    {:noreply, assign(socket, :comment_reply_content, content)}
  end

  def handle_event("submit_comment_reply", %{"content" => content}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to reply")}
    else
      if String.trim(content) == "" do
        {:noreply, put_flash(socket, :error, "Reply cannot be empty")}
      else
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

                new_reply_ap = %{
                  "id" => reply.activitypub_id || "#{base_url}/messages/#{reply.id}",
                  "type" => "Note",
                  "attributedTo" => "#{base_url}/users/#{user.username}",
                  "content" => content,
                  "published" => NaiveDateTime.to_iso8601(reply.inserted_at) <> "Z",
                  "inReplyTo" => comment_id,
                  "likes" => %{"totalItems" => 0},
                  "_local" => true,
                  "_local_user" => user,
                  "_local_message_id" => reply.id
                }

                # Add new reply to existing replies
                updated_replies = socket.assigns.replies ++ [new_reply_ap]

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
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to reply")}
    else
      if String.trim(content) == "" do
        {:noreply, put_flash(socket, :error, "Reply cannot be empty")}
      else
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
                "_local" => true,
                "_local_user" => user,
                "_local_message_id" => reply.id
              }

              updated_replies = socket.assigns.replies ++ [new_reply_ap]

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
                    "_local" => true,
                    "_local_user" => user,
                    "_local_message_id" => reply.id
                  }

                  # Add new reply to existing replies
                  updated_replies = socket.assigns.replies ++ [new_reply_ap]

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
      end
    end
  end

  def handle_event("like_post", %{"message_id" => message_id}, socket) do
    Interactions.like_message(socket, message_id,
      on_refresh: &maybe_assign_displayed_local_message/2
    )
  end

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    Interactions.like_post(socket, post_id, on_refresh: &assign_local_message/2)
  end

  def handle_event("unlike_post", %{"message_id" => message_id}, socket) do
    Interactions.unlike_message(socket, message_id,
      on_refresh: &maybe_assign_displayed_local_message/2
    )
  end

  def handle_event("unlike_post", %{"post_id" => post_id}, socket) do
    Interactions.unlike_post(socket, post_id, on_refresh: &assign_local_message/2)
  end

  def handle_event("toggle_modal_like", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
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
    Interactions.boost_message(socket, message_id,
      on_refresh: &maybe_assign_displayed_local_message/2
    )
  end

  def handle_event("boost_post", %{"post_id" => post_id}, socket) do
    Interactions.boost_post(socket, post_id, on_share_delta: &maybe_adjust_local_share_count/3)
  end

  def handle_event("unboost_post", %{"message_id" => message_id}, socket) do
    Interactions.unboost_message(socket, message_id,
      on_refresh: &maybe_assign_displayed_local_message/2
    )
  end

  def handle_event("unboost_post", %{"post_id" => post_id}, socket) do
    Interactions.unboost_post(socket, post_id, on_share_delta: &maybe_adjust_local_share_count/3)
  end

  # Save/bookmark post handlers
  def handle_event("save_post", %{"post_id" => post_id}, socket) do
    Interactions.save_message(socket, post_id)
  end

  def handle_event("save_post", %{"message_id" => message_id}, socket) do
    Interactions.save_message(socket, message_id)
  end

  def handle_event("unsave_post", %{"post_id" => post_id}, socket) do
    Interactions.unsave_message(socket, post_id)
  end

  def handle_event("unsave_post", %{"message_id" => message_id}, socket) do
    Interactions.unsave_message(socket, message_id)
  end

  # Reddit-style voting for Lemmy community posts
  def handle_event("vote_post", %{"type" => vote_type}, socket) do
    Interactions.vote_remote_target(socket, socket.assigns.post["id"], vote_type,
      target_label: "post"
    )
  end

  # Reddit-style voting for Lemmy comments
  def handle_event("vote_comment", %{"comment_id" => comment_id, "type" => vote_type}, socket) do
    Interactions.vote_remote_target(socket, comment_id, vote_type, target_label: "comment")
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
    images = Jason.decode!(images_json)

    # Construct modal_post with actor context for display in the image modal
    modal_post =
      cond do
        # For local posts, use the local_message with its sender
        socket.assigns.is_local_post && socket.assigns.local_message ->
          socket.assigns.local_message

        # For remote posts, create a pseudo-post with remote_actor context
        socket.assigns.remote_actor ->
          # Parse the published date if available
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
            activitypub_id: socket.assigns.post && socket.assigns.post["id"]
          }

        true ->
          nil
      end

    {:noreply,
     socket
     |> assign(:show_image_modal, true)
     |> assign(:modal_image_url, url)
     |> assign(:modal_images, images)
     |> assign(:modal_image_index, String.to_integer(index))
     |> assign(:modal_post, modal_post)}
  end

  def handle_event("close_image_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_image_modal, false)
     |> assign(:modal_image_url, nil)
     |> assign(:modal_images, [])
     |> assign(:modal_image_index, 0)
     |> assign(:modal_post, nil)}
  end

  def handle_event("next_image", _params, socket) do
    new_index = rem(socket.assigns.modal_image_index + 1, length(socket.assigns.modal_images))
    new_url = Enum.at(socket.assigns.modal_images, new_index)

    {:noreply,
     socket
     |> assign(:modal_image_index, new_index)
     |> assign(:modal_image_url, new_url)}
  end

  def handle_event("prev_image", _params, socket) do
    total = length(socket.assigns.modal_images)
    new_index = rem(socket.assigns.modal_image_index - 1 + total, total)
    new_url = Enum.at(socket.assigns.modal_images, new_index)

    {:noreply,
     socket
     |> assign(:modal_image_index, new_index)
     |> assign(:modal_image_url, new_url)}
  end

  def handle_event("sort_comments", %{"sort" => sort}, socket) do
    {threaded_replies, thread_reply_actors} =
      build_threaded_replies_with_actor_cache(
        socket.assigns.replies,
        socket.assigns.post["id"],
        sort
      )

    {:noreply,
     socket
     |> assign(:comment_sort, sort)
     |> assign(:threaded_replies, threaded_replies)
     |> assign(:thread_reply_actors, thread_reply_actors)}
  end

  def handle_event("load_comments", _params, socket) do
    if socket.assigns.post do
      send(self(), {:load_replies, socket.assigns.post})
      {:noreply, assign(socket, :replies_loading, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("refresh_comments", _params, socket) do
    if socket.assigns.post do
      # Force refresh - refetch from remote
      send(self(), {:load_replies, socket.assigns.post})
      {:noreply, assign(socket, :replies_loading, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_follow_community", _params, socket) do
    require Logger

    if current_user_missing?(socket) do
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

  def handle_event("vote_remote_poll", %{"option_name" => option_name}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    else
      post = socket.assigns.post
      remote_actor = socket.assigns.remote_actor

      # Send vote via ActivityPub
      Task.start(fn ->
        Elektrine.ActivityPub.Outbox.send_poll_vote(
          socket.assigns.current_user,
          post["id"],
          option_name,
          remote_actor
        )
      end)

      {:noreply, put_flash(socket, :info, "Vote sent to #{remote_actor.domain}")}
    end
  end

  # Catch-all for unhandled events (e.g., connection_changed from JS)
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  defp normalize_navigate_post_id(socket, value) do
    decoded_value = decode_post_ref(value)

    case parse_local_message_id(decoded_value) do
      {:ok, id} ->
        case socket.assigns[:local_message] do
          %{id: ^id, activitypub_id: activitypub_id}
          when is_binary(activitypub_id) and activitypub_id != "" ->
            activitypub_id

          _ ->
            Integer.to_string(id)
        end

      :error ->
        to_string(decoded_value)
    end
  end

  defp parse_local_message_id(value) when is_integer(value), do: {:ok, value}

  defp parse_local_message_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_local_message_id(_), do: :error

  defp decode_post_ref(value) when is_binary(value) do
    trimmed = String.trim(value)

    try do
      URI.decode_www_form(trimmed)
    rescue
      ArgumentError -> trimmed
    end
  end

  defp decode_post_ref(value), do: value

  defp initial_community_stats(%{actor_type: "Group", metadata: metadata}) do
    metadata = metadata || %{}

    %{
      members: get_follower_count(metadata),
      posts: get_status_count(metadata)
    }
  end

  defp initial_community_stats(_), do: %{members: 0, posts: 0}

  defp fetch_group_stats(%{domain: domain, username: username, metadata: metadata}) do
    metadata = metadata || %{}
    metadata_stats = initial_community_stats(%{actor_type: "Group", metadata: metadata})

    followers_collection_count = fetch_collection_count(metadata["followers"])
    outbox_collection_count = fetch_collection_count(metadata["outbox"])
    lemmy_stats = Elektrine.ActivityPub.LemmyApi.fetch_community_counts(domain, username) || %{}

    %{
      members:
        Enum.max([
          metadata_stats.members || 0,
          followers_collection_count,
          lemmy_stats[:members] || 0
        ]),
      posts:
        Enum.max([
          metadata_stats.posts || 0,
          outbox_collection_count,
          lemmy_stats[:posts] || 0
        ])
    }
  end

  defp fetch_group_stats(_), do: %{members: 0, posts: 0}

  defp fetch_collection_count(nil), do: 0

  defp fetch_collection_count(url) when is_binary(url) do
    case Elektrine.ActivityPub.CollectionFetcher.fetch_collection_count(url) do
      {:ok, count} when is_integer(count) -> max(count, 0)
      _ -> 0
    end
  end

  defp fetch_collection_count(collection) when is_map(collection) do
    case Elektrine.ActivityPub.CollectionFetcher.fetch_collection_count(collection) do
      {:ok, count} when is_integer(count) -> max(count, 0)
      _ -> 0
    end
  end

  defp fetch_collection_count(_), do: 0

  # Helper functions - delegating to shared APHelpers module

  defp maybe_adjust_local_share_count(socket, post_id, delta) do
    local_message = socket.assigns[:local_message]
    displayed_post_id = get_in(socket.assigns, [:post, "id"])

    if is_map(local_message) && post_id == displayed_post_id do
      current_count = local_message.share_count || 0
      updated_count = max(current_count + delta, 0)
      assign(socket, :local_message, %{local_message | share_count: updated_count})
    else
      socket
    end
  end

  defp maybe_assign_displayed_local_message(socket, nil), do: socket

  defp maybe_assign_displayed_local_message(socket, message) do
    local_message = socket.assigns[:local_message]

    if is_map(local_message) && local_message.id == message.id do
      assign(socket, :local_message, %{
        local_message
        | like_count: message.like_count,
          share_count: message.share_count,
          reply_count: message.reply_count,
          quote_count: message.quote_count
      })
    else
      socket
    end
  end

  defp assign_local_message(socket, nil), do: socket
  defp assign_local_message(socket, message), do: assign(socket, :local_message, message)

  defp format_activitypub_date(date), do: APHelpers.format_activitypub_date(date)
  defp get_collection_total_items(coll), do: APHelpers.get_collection_total(coll)
  defp get_follower_count(meta), do: APHelpers.get_follower_count(meta)
  defp get_status_count(meta), do: APHelpers.get_status_count(meta)
  defp format_join_date(date), do: APHelpers.format_join_date(date)

  defp load_post_interactions(posts, user_id),
    do: APHelpers.load_post_interactions(posts, user_id)

  defp get_or_store_remote_post(activitypub_id, actor_uri) do
    APHelpers.get_or_store_remote_post(activitypub_id, actor_uri)
  end

  defp build_threaded_replies_with_actor_cache(replies, post_id, sort) do
    Threading.build_threaded_replies_with_actor_cache(replies, post_id, sort)
  end

  defp quick_reply_author_preview(reply) when is_map(reply) do
    local_user = Map.get(reply, "_local_user") || Map.get(reply, :_local_user)

    if is_map(local_user) do
      username = Map.get(local_user, :username) || Map.get(local_user, "username")
      handle = Map.get(local_user, :handle) || Map.get(local_user, "handle") || username
      avatar = Map.get(local_user, :avatar) || Map.get(local_user, "avatar")

      avatar_url =
        if is_binary(avatar) && String.trim(avatar) != "" do
          Elektrine.Uploads.avatar_url(avatar)
        else
          nil
        end

      %{
        label: "@#{handle}@#{Elektrine.Domains.default_user_handle_domain()}",
        avatar_url: avatar_url,
        profile_path: if(is_binary(handle) && handle != "", do: "/#{handle}", else: nil)
      }
    else
      author_uri =
        Map.get(reply, "attributedTo") || Map.get(reply, :attributedTo) ||
          Map.get(reply, "actor") || Map.get(reply, :actor)

      fallback = SurfaceHelpers.build_reply_author_fallback(reply, author_uri)

      label =
        cond do
          is_binary(fallback.acct_label) && String.trim(fallback.acct_label) != "" ->
            fallback.acct_label

          is_binary(author_uri) && String.trim(author_uri) != "" ->
            "@#{extract_username_from_uri(author_uri)}"

          true ->
            "Remote user"
        end

      %{
        label: label,
        avatar_url: fallback.avatar_url,
        profile_path: fallback.profile_path
      }
    end
  end

  defp quick_reply_author_preview(_),
    do: %{label: "Remote user", avatar_url: nil, profile_path: nil}

  defp extract_username_from_uri(uri), do: SurfaceHelpers.extract_username_from_uri(uri)

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

  defp current_user_missing?(socket), do: is_nil(socket.assigns[:current_user])
end
