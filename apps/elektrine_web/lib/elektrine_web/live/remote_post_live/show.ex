defmodule ElektrineWeb.RemotePostLive.Show do
  use ElektrineWeb, :live_view

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Helpers, as: APHelpers
  alias ElektrineWeb.Live.PostInteractions
  alias Elektrine.Social

  import ElektrineWeb.Components.Platform.ZNav
  import ElektrineWeb.HtmlHelpers
  import ElektrineWeb.Components.Loaders.Skeleton

  # Render threaded comments recursively
  # Detects if this is a Lemmy post (has community_actor) and renders accordingly
  def render_threaded_comments(assigns, comments) do
    # Determine if this is a Lemmy post based on presence of community_actor
    is_lemmy_post = assigns[:community_actor] != nil
    reply_content_domain = if(assigns[:remote_actor], do: assigns.remote_actor.domain, else: nil)

    assigns =
      assigns
      |> assign(:comments, comments)
      |> assign(:is_lemmy_post, is_lemmy_post)
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

      # Timeline threads should stay readable; communities keep deep trees
      show_nested_timeline_replies = @is_lemmy_post || depth < 1
      show_origin_thread_link = !@is_lemmy_post && depth >= 1 && reply_child_count > 0

      origin_thread_url =
        cond do
          is_binary(@post["id"]) -> @post["id"]
          is_binary(@post["url"]) -> @post["url"]
          true -> nil
        end

      is_local_reply = reply["_local"] == true
      local_user = reply["_local_user"]
      reply_author_uri = reply["attributedTo"]

      reply_actor =
        cond do
          # We'll use local_user directly
          is_local_reply && local_user -> nil
          reply_author_uri -> Elektrine.ActivityPub.get_actor_by_uri(reply_author_uri)
          true -> nil
        end

      # Keep visual distinction by surface: threaded trees for communities,
      # shallow conversational layout for timeline-style threads.
      indent_class =
        if @is_lemmy_post do
          case min(depth, 4) do
            0 -> ""
            1 -> "border-l-2 border-base-content/20 pl-3 ml-2"
            2 -> "border-l-2 border-base-content/15 pl-3 ml-4"
            3 -> "border-l-2 border-base-content/10 pl-3 ml-6"
            _ -> "border-l-2 border-base-content/10 pl-3 ml-8"
          end
        else
          case min(depth, 2) do
            0 -> ""
            1 -> "border-l-2 border-base-content/20 pl-3 ml-2"
            _ -> "border-l-2 border-base-content/15 pl-3 ml-2"
          end
        end %>
      <div class={indent_class}>
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
              <div class="flex items-center gap-2 text-xs mb-1">
                <%= if is_local_reply && local_user do %>
                  <.link
                    navigate={"/#{local_user.handle || local_user.username}"}
                    class="font-medium text-info hover:underline"
                  >
                    {local_user.display_name || local_user.username}
                  </.link>
                  <%= if @current_user && @current_user.id == local_user.id do %>
                    <span class="text-info/70">(you)</span>
                  <% end %>
                <% else %>
                  <%= if reply_actor do %>
                    <.link
                      navigate={"/remote/#{reply_actor.username}@#{reply_actor.domain}"}
                      class="font-medium hover:underline"
                    >
                      {raw(
                        render_display_name_with_emojis(
                          reply_actor.display_name || reply_actor.username,
                          reply_actor.domain
                        )
                      )}
                    </.link>
                  <% else %>
                    <span class="font-medium">{extract_username_from_uri(reply_author_uri)}</span>
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
                <.link navigate={"/#{local_user.handle || local_user.username}"} class="flex-shrink-0">
                  <%= if local_user.avatar do %>
                    <img
                      src={Elektrine.Uploads.avatar_url(local_user.avatar)}
                      alt={local_user.username}
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
                <%= if reply_actor do %>
                  <.link
                    navigate={"/remote/#{reply_actor.username}@#{reply_actor.domain}"}
                    class="flex-shrink-0"
                  >
                    <%= if reply_actor.avatar_url do %>
                      <img
                        src={reply_actor.avatar_url}
                        alt={reply_actor.username}
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
                      navigate={"/remote/#{reply_actor.username}@#{reply_actor.domain}"}
                      class="text-sm font-medium hover:text-purple-600 transition-colors"
                    >
                      {raw(
                        render_display_name_with_emojis(
                          reply_actor.display_name || reply_actor.username,
                          reply_actor.domain
                        )
                      )}
                    </.link>
                    <div class="text-xs opacity-50">
                      @{reply_actor.username}@{reply_actor.domain} · {if reply["published"],
                        do: format_activitypub_date(reply["published"])}
                    </div>
                  </div>
                <% else %>
                  <div class="w-8 h-8 rounded-full bg-base-300 flex items-center justify-center flex-shrink-0">
                    <.icon name="hero-user" class="w-4 h-4" />
                  </div>
                  <div class="flex-1 min-w-0">
                    <span class="text-sm font-medium">
                      {extract_username_from_uri(reply_author_uri)}
                    </span>
                    <div class="text-xs opacity-50">
                      {if reply["published"], do: format_activitypub_date(reply["published"])}
                    </div>
                  </div>
                <% end %>
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
          <%= if show_nested_timeline_replies do %>
            {render_threaded_comments(assigns, children)}
          <% else %>
            <div class="ml-2 mb-3">
              <%= if show_origin_thread_link && origin_thread_url do %>
                <a
                  href={origin_thread_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="text-xs text-primary hover:underline inline-flex items-center gap-1"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                  Continue {reply_child_count} nested {if reply_child_count == 1,
                    do: "reply",
                    else: "replies"} on origin thread
                </a>
              <% else %>
                <span class="text-xs text-base-content/50">
                  {reply_child_count} nested {if reply_child_count == 1, do: "reply", else: "replies"}
                </span>
              <% end %>
            </div>
          <% end %>
        <% end %>
      </div>
    <% end %>
    """
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

    # Initialize with loading state
    socket =
      socket
      |> assign(:page_title, "Loading post...")
      |> assign(:loading, true)
      |> assign(:load_error, nil)
      |> assign(:post_id, decoded_post_id)
      |> assign(:is_local_post, is_local_post)
      |> assign(:local_message, nil)
      |> assign(:post, nil)
      |> assign(:remote_actor, nil)
      |> assign(:community_actor, nil)
      |> assign(:is_following_community, false)
      |> assign(:is_pending_community, false)
      |> assign(:replies, [])
      |> assign(:threaded_replies, [])
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
      |> assign(:meta_description, nil)
      |> assign(:og_image, nil)
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

            # Build post object from cached message
            post_object = build_post_object_from_message(msg)

            socket
            |> assign(:local_message, msg)
            |> assign(:post, post_object)
            |> assign(:remote_actor, msg.remote_actor)
            |> assign(:loading, false)
            |> assign(
              :page_title,
              msg.title || "Post by @#{(msg.remote_actor && msg.remote_actor.username) || "user"}"
            )

          nil ->
            socket
        end
      end

    # Defer full HTTP fetching to handle_info for interactive use
    if connected?(socket) do
      if is_local_post do
        send(self(), {:load_local_post, String.to_integer(decoded_post_id)})
      else
        # For cached content, check if it's a community post that needs community loaded
        cached_msg = socket.assigns[:local_message]

        if cached_msg do
          # Check if it's a community/Lemmy-like post that needs community loaded
          # Patterns: /post/ (Lemmy), /c/.../p/ (PieFed), or any post with Page type
          # Always try to load community for federated posts - it will be nil if none exists
          if cached_msg.activitypub_id && community_post_url?(cached_msg.activitypub_id) do
            send(self(), {:load_community_for_cached, decoded_post_id})
          end

          # Load main post interactions immediately for cached posts
          send(self(), {:load_main_post_interactions, cached_msg})

          # Load replies and counts for cached posts
          send(self(), {:load_replies_for_cached, cached_msg})
          send(self(), {:load_platform_counts, decoded_post_id})
          send(self(), {:load_reactions, decoded_post_id})
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
    String.contains?(url, "/post/") ||
      Regex.match?(~r{/c/[^/]+/p/}, url) ||
      Regex.match?(~r{/m/[^/]+/p/}, url) ||
      Regex.match?(~r{/m/[^/]+/t/}, url)
  end

  defp community_post_url?(_), do: false

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

  # Calculate the score delta change when voting
  # Reddit-style: upvote = +1, downvote = -1, removing vote reverses
  defp calculate_vote_delta_change(old_vote, new_vote) do
    old_value = vote_to_value(old_vote)
    new_value = vote_to_value(new_vote)
    new_value - old_value
  end

  defp vote_to_value("up"), do: 1
  defp vote_to_value("down"), do: -1
  defp vote_to_value(_), do: 0

  # Build an ActivityPub-like post object from a local message
  defp build_post_object_from_message(msg) do
    poll_fields = build_poll_fields_from_message(msg)
    reply_count = cached_reply_count(msg)

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
      "type" => "Note",
      "content" => msg.content,
      "published" => NaiveDateTime.to_iso8601(msg.inserted_at) <> "Z",
      "attributedTo" => msg.remote_actor && msg.remote_actor.uri,
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

  defp preload_cached_message_associations(message) do
    Elektrine.Repo.preload(message, Elektrine.Messaging.Messages.timeline_post_preloads())
  end

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
        title = message.title || "Post by #{message.sender.username}"

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

            # Try to get actor name
            actor_name =
              case ActivityPub.get_actor_by_uri(post_object["attributedTo"]) do
                %{username: u, domain: d} -> "@#{u}@#{d}"
                _ -> nil
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

      post_object = %{
        "id" => "#{base_url}/posts/#{message.id}",
        "type" => "Note",
        "content" => message.content,
        "published" => NaiveDateTime.to_iso8601(message.inserted_at) <> "Z",
        "attributedTo" => post_attributed_to,
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

      threaded_replies =
        build_reply_tree(local_replies, post_object["id"], socket.assigns.comment_sort)

      local_post_key = Integer.to_string(message.id)

      reactions =
        from(r in Elektrine.Messaging.MessageReaction,
          where: r.message_id == ^message.id,
          preload: [:user, :remote_actor]
        )
        |> Elektrine.Repo.all()

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

      {:noreply,
       socket
       |> assign(:loading, false)
       |> assign(:post, post_object)
       |> assign(:local_message, message)
       |> assign(:remote_actor, nil)
       |> assign(:page_title, page_title)
       |> assign(:replies, local_replies)
       |> assign(
         :quick_reply_recent_replies,
         recent_replies_for_preview(local_replies, post_object["id"])
       )
       |> assign(:threaded_replies, threaded_replies)
       |> assign(:replies_loading, false)
       |> assign(:replies_loaded, true)
       |> assign(:post_interactions, post_interactions)
       |> assign(:user_saves, user_saves)
       |> assign(
         :post_reactions,
         Map.put(socket.assigns.post_reactions, local_post_key, reactions)
       )}
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
          |> assign(
            :page_title,
            post_object["name"] || "Post by @#{remote_actor.username}@#{remote_actor.domain}"
          )
          |> assign(:post, post_object)
          |> assign(:remote_actor, remote_actor)
          |> assign(:community_actor, community_actor)
          |> assign(:is_following_community, is_following_community)
          |> assign(:is_pending_community, is_pending_community)

        # Update local message counts with fresh data from source (async)
        Task.start(fn -> Elektrine.Messaging.Messages.sync_remote_counts(post_object) end)

        socket = assign(socket, :local_message, local_message)

        # Load main post interactions immediately
        socket =
          if socket.assigns[:current_user] do
            interactions = load_post_interactions([post_object], socket.assigns.current_user.id)
            assign(socket, :post_interactions, interactions)
          else
            socket
          end

        # Defer replies and platform-specific counts loading
        send(self(), {:load_replies, post_object})
        send(self(), {:load_platform_counts, post_object["id"]})
        send(self(), {:load_reactions, post_object["id"]})

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

  # Load community actor for cached community posts
  def handle_info({:load_community_for_cached, post_id}, socket) do
    liveview_pid = self()

    Task.start(fn ->
      # Fetch the post to get the community URI from various fields
      case ActivityPub.Fetcher.fetch_object(post_id) do
        {:ok, post_object} ->
          # Check multiple fields for community URI
          community_uri =
            cond do
              is_binary(post_object["audience"]) ->
                post_object["audience"]

              is_list(post_object["to"]) ->
                Enum.find(post_object["to"], fn uri ->
                  is_binary(uri) && (String.contains?(uri, "/c/") || String.contains?(uri, "/m/"))
                end)

              is_binary(post_object["context"]) && String.contains?(post_object["context"], "/c/") ->
                post_object["context"]

              true ->
                nil
            end

          if community_uri do
            case ActivityPub.get_or_fetch_actor(community_uri) do
              {:ok, community_actor} ->
                send(liveview_pid, {:community_loaded, community_actor})

              _ ->
                :ok
            end
          end

        _ ->
          :ok
      end
    end)

    {:noreply, socket}
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

    {:noreply,
     socket
     |> assign(:community_actor, community_actor)
     |> assign(:is_following_community, is_following_community)
     |> assign(:is_pending_community, is_pending_community)}
  end

  # Load replies for cached posts
  def handle_info({:load_replies_for_cached, msg}, socket) do
    post_id = msg.activitypub_id || msg.activitypub_url
    post_url = msg.activitypub_url || post_id
    replies_count = cached_reply_count(msg)
    replies_object = cached_replies_object(msg, replies_count)
    comments_object = cached_comments_object(msg, replies_count)

    is_community_post =
      community_post_url?(post_id || "") || community_post_url?(post_url || "")

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

    {:noreply, socket}
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
    merged_replies = merge_local_replies(replies, post_id)

    # Build threaded replies structure
    threaded_replies = build_reply_tree(merged_replies, post_id, socket.assigns.comment_sort)

    # Load interaction state for current user
    all_posts =
      if socket.assigns.post, do: [socket.assigns.post | merged_replies], else: merged_replies

    post_interactions =
      if socket.assigns[:current_user] do
        load_post_interactions(all_posts, socket.assigns.current_user.id)
      else
        %{}
      end

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
     |> assign(:quick_reply_recent_replies, recent_replies_for_preview(merged_replies, post_id))
     |> assign(:threaded_replies, threaded_replies)
     |> assign(:replies_loading, false)
     |> assign(:replies_loaded, true)
     |> assign(:post_interactions, post_interactions)}
  end

  def handle_info({:load_platform_counts, post_id}, socket) do
    # Detect platform and fetch appropriate counts
    cond do
      # Lemmy/community posts - check for various URL patterns
      # /post/ (Lemmy), /c/.../p/ (PieFed), /m/.../p/ or /m/.../t/ (Mbin)
      String.contains?(post_id, "/post/") ||
        Regex.match?(~r{/c/[^/]+/p/}, post_id) ||
          Regex.match?(~r{/m/[^/]+/[pt]/}, post_id) ->
        # Try to fetch Lemmy-style counts (works for Lemmy, may work for compatible platforms)
        lemmy_counts = Elektrine.ActivityPub.LemmyApi.fetch_post_counts(post_id)
        lemmy_comment_counts = Elektrine.ActivityPub.LemmyApi.fetch_comment_counts(post_id)

        {:noreply,
         socket
         |> assign(:lemmy_counts, lemmy_counts)
         |> assign(:lemmy_comment_counts, lemmy_comment_counts)
         |> assign(:mastodon_counts, nil)}

      # Mastodon-compatible posts
      Elektrine.ActivityPub.MastodonApi.is_mastodon_compatible?(%{activitypub_id: post_id}) ->
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

        {:noreply, assign(socket, :post_reactions, %{activitypub_id => reactions})}
    end
  end

  def handle_info({:refresh_remote_counts, post_id}, socket) do
    # Refresh Lemmy-specific counts
    lemmy_counts = Elektrine.ActivityPub.LemmyApi.fetch_post_counts(post_id)
    lemmy_comment_counts = Elektrine.ActivityPub.LemmyApi.fetch_comment_counts(post_id)

    # Also refresh the post object for non-Lemmy posts to get fresh counts
    socket =
      if socket.assigns.post && !String.contains?(post_id, "/post/") do
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
        case resolve_comment_target_message(comment_id, socket.assigns.replies) do
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

                threaded_replies =
                  build_reply_tree(
                    updated_replies,
                    socket.assigns.post["id"],
                    socket.assigns.comment_sort
                  )

                {:noreply,
                 socket
                 |> assign(:replies, updated_replies)
                 |> assign(
                   :quick_reply_recent_replies,
                   recent_replies_for_preview(updated_replies, socket.assigns.post["id"])
                 )
                 |> assign(:threaded_replies, threaded_replies)
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

              threaded_replies =
                build_reply_tree(updated_replies, post["id"], socket.assigns.comment_sort)

              updated_local_message = %{
                local_message
                | reply_count: max((local_message.reply_count || 0) + 1, length(updated_replies))
              }

              {:noreply,
               socket
               |> assign(:replies, updated_replies)
               |> assign(
                 :quick_reply_recent_replies,
                 recent_replies_for_preview(updated_replies, post["id"])
               )
               |> assign(:threaded_replies, threaded_replies)
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

                  threaded_replies =
                    build_reply_tree(
                      updated_replies,
                      socket.assigns.post["id"],
                      socket.assigns.comment_sort
                    )

                  {:noreply,
                   socket
                   |> assign(:replies, updated_replies)
                   |> assign(
                     :quick_reply_recent_replies,
                     recent_replies_for_preview(updated_replies, socket.assigns.post["id"])
                   )
                   |> assign(:threaded_replies, threaded_replies)
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
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: socket.assigns[:remote_actor] && socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          case Elektrine.Social.like_post(socket.assigns.current_user.id, message.id) do
            {:ok, _like} ->
              key = PostInteractions.interaction_key(message_id, message)

              current_state =
                socket.assigns.post_interactions[key] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, key, %{
                  liked: true,
                  boosted: Map.get(current_state, :boosted, false),
                  like_delta: Map.get(current_state, :like_delta, 0) + 1,
                  boost_delta: Map.get(current_state, :boost_delta, 0)
                })

              fresh_message = Elektrine.Repo.get(Elektrine.Messaging.Message, message.id)

              {:noreply,
               socket
               |> assign(:post_interactions, post_interactions)
               |> maybe_assign_displayed_local_message(fresh_message)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to like post")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process post")}
      end
    end
  end

  def handle_event("like_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to like posts")}
    else
      # Use single-arg version to fetch correct actor from object (important for comments)
      case APHelpers.get_or_store_remote_post(post_id) do
        {:ok, message} ->
          case Elektrine.Social.like_post(socket.assigns.current_user.id, message.id) do
            {:ok, _like} ->
              current_state =
                socket.assigns.post_interactions[post_id] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, post_id, %{
                  liked: true,
                  boosted: Map.get(current_state, :boosted, false),
                  like_delta: Map.get(current_state, :like_delta, 0) + 1,
                  boost_delta: Map.get(current_state, :boost_delta, 0)
                })

              # Reload local message to get updated like_count
              fresh_message = Elektrine.Repo.get(Elektrine.Messaging.Message, message.id)

              {:noreply,
               socket
               |> assign(:post_interactions, post_interactions)
               |> assign(:local_message, fresh_message)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to like post")}
          end

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "This content has been deleted")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process remote post")}
      end
    end
  end

  def handle_event("unlike_post", %{"message_id" => message_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: socket.assigns[:remote_actor] && socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          case Elektrine.Social.unlike_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              key = PostInteractions.interaction_key(message_id, message)

              current_state =
                socket.assigns.post_interactions[key] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, key, %{
                  liked: false,
                  boosted: Map.get(current_state, :boosted, false),
                  like_delta: Map.get(current_state, :like_delta, 0) - 1,
                  boost_delta: Map.get(current_state, :boost_delta, 0)
                })

              fresh_message = Elektrine.Repo.get(Elektrine.Messaging.Message, message.id)

              {:noreply,
               socket
               |> assign(:post_interactions, post_interactions)
               |> maybe_assign_displayed_local_message(fresh_message)}

            {:error, _} ->
              {:noreply, socket}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("unlike_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case Elektrine.Messaging.get_message_by_activitypub_id(post_id) do
        nil ->
          {:noreply, socket}

        message ->
          case Elektrine.Social.unlike_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              current_state =
                socket.assigns.post_interactions[post_id] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, post_id, %{
                  liked: false,
                  boosted: Map.get(current_state, :boosted, false),
                  like_delta: Map.get(current_state, :like_delta, 0) - 1,
                  boost_delta: Map.get(current_state, :boost_delta, 0)
                })

              # Reload local message to get updated like_count
              fresh_message = Elektrine.Repo.get(Elektrine.Messaging.Message, message.id)

              {:noreply,
               socket
               |> assign(:post_interactions, post_interactions)
               |> assign(:local_message, fresh_message)}

            {:error, _} ->
              {:noreply, socket}
          end
      end
    end
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
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to boost posts")}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: socket.assigns[:remote_actor] && socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          case Elektrine.Social.boost_post(socket.assigns.current_user.id, message.id) do
            {:ok, _boost} ->
              key = PostInteractions.interaction_key(message_id, message)

              current_state =
                socket.assigns.post_interactions[key] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, key, %{
                  liked: Map.get(current_state, :liked, false),
                  boosted: true,
                  like_delta: Map.get(current_state, :like_delta, 0),
                  boost_delta: Map.get(current_state, :boost_delta, 0) + 1
                })

              fresh_message = Elektrine.Repo.get(Elektrine.Messaging.Message, message.id)

              {:noreply,
               socket
               |> assign(:post_interactions, post_interactions)
               |> maybe_assign_displayed_local_message(fresh_message)
               |> put_flash(:info, "Post boosted to your timeline!")}

            {:error, :already_boosted} ->
              {:noreply, put_flash(socket, :info, "You've already boosted this post")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to boost post")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process post")}
      end
    end
  end

  def handle_event("boost_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to boost posts")}
    else
      # Use single-arg version to fetch correct actor from object (important for comments)
      case APHelpers.get_or_store_remote_post(post_id) do
        {:ok, message} ->
          case Elektrine.Social.boost_post(socket.assigns.current_user.id, message.id) do
            {:ok, _boost} ->
              current_state =
                socket.assigns.post_interactions[post_id] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, post_id, %{
                  liked: Map.get(current_state, :liked, false),
                  boosted: true,
                  like_delta: Map.get(current_state, :like_delta, 0),
                  boost_delta: Map.get(current_state, :boost_delta, 0) + 1
                })

              {:noreply,
               socket
               |> assign(:post_interactions, post_interactions)
               |> maybe_adjust_local_share_count(post_id, 1)
               |> put_flash(:info, "Post boosted to your timeline!")}

            {:error, :already_boosted} ->
              {:noreply, put_flash(socket, :info, "You've already boosted this post")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to boost post")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process remote post")}
      end
    end
  end

  def handle_event("unboost_post", %{"message_id" => message_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: socket.assigns[:remote_actor] && socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          case Elektrine.Social.unboost_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              key = PostInteractions.interaction_key(message_id, message)

              current_state =
                socket.assigns.post_interactions[key] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, key, %{
                  liked: Map.get(current_state, :liked, false),
                  boosted: false,
                  like_delta: Map.get(current_state, :like_delta, 0),
                  boost_delta: Map.get(current_state, :boost_delta, 0) - 1
                })

              fresh_message = Elektrine.Repo.get(Elektrine.Messaging.Message, message.id)

              {:noreply,
               socket
               |> assign(:post_interactions, post_interactions)
               |> maybe_assign_displayed_local_message(fresh_message)}

            {:error, _} ->
              {:noreply, socket}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("unboost_post", %{"post_id" => post_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case Elektrine.Messaging.get_message_by_activitypub_id(post_id) do
        nil ->
          {:noreply, socket}

        message ->
          case Elektrine.Social.unboost_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              current_state =
                socket.assigns.post_interactions[post_id] ||
                  %{liked: false, boosted: false, like_delta: 0, boost_delta: 0}

              post_interactions =
                Map.put(socket.assigns.post_interactions, post_id, %{
                  liked: Map.get(current_state, :liked, false),
                  boosted: false,
                  like_delta: Map.get(current_state, :like_delta, 0),
                  boost_delta: Map.get(current_state, :boost_delta, 0) - 1
                })

              {:noreply,
               socket
               |> assign(:post_interactions, post_interactions)
               |> maybe_adjust_local_share_count(post_id, -1)}

            {:error, _} ->
              {:noreply, socket}
          end
      end
    end
  end

  # Save/bookmark post handlers
  def handle_event("save_post", %{"post_id" => post_id}, socket) do
    handle_event("save_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("save_post", %{"message_id" => message_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to save posts")}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: socket.assigns[:remote_actor] && socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          case Social.save_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              user_saves = Map.get(socket.assigns, :user_saves, %{})
              key = PostInteractions.interaction_key(message_id, message)

              {:noreply,
               socket
               |> assign(:user_saves, Map.put(user_saves, key, true))
               |> put_flash(:info, "Saved")}

            {:error, _} ->
              user_saves = Map.get(socket.assigns, :user_saves, %{})
              key = PostInteractions.interaction_key(message_id, message)

              {:noreply,
               socket
               |> assign(:user_saves, Map.put(user_saves, key, true))
               |> put_flash(:info, "Already saved")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save post")}
      end
    end
  end

  def handle_event("unsave_post", %{"post_id" => post_id}, socket) do
    handle_event("unsave_post", %{"message_id" => post_id}, socket)
  end

  def handle_event("unsave_post", %{"message_id" => message_id}, socket) do
    if current_user_missing?(socket) do
      {:noreply, socket}
    else
      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: socket.assigns[:remote_actor] && socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          case Social.unsave_post(socket.assigns.current_user.id, message.id) do
            {:ok, _} ->
              user_saves = Map.get(socket.assigns, :user_saves, %{})
              key = PostInteractions.interaction_key(message_id, message)

              {:noreply,
               socket
               |> assign(:user_saves, Map.put(user_saves, key, false))
               |> put_flash(:info, "Removed from saved")}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to unsave")}
          end

        {:error, _} ->
          {:noreply, socket}
      end
    end
  end

  # Reddit-style voting for Lemmy community posts
  def handle_event("vote_post", %{"type" => vote_type}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    else
      post_id = socket.assigns.post["id"]

      case APHelpers.get_or_store_remote_post(post_id) do
        {:ok, message} ->
          user_id = socket.assigns.current_user.id
          current_state = Map.get(socket.assigns.post_interactions, post_id, %{})
          current_vote = Map.get(current_state, :vote, nil)
          current_vote_delta = Map.get(current_state, :vote_delta, 0)

          # Determine the new vote state
          new_vote =
            if current_vote == vote_type, do: nil, else: vote_type

          # Calculate the vote delta change for optimistic UI update
          # Each vote change affects the score differently
          vote_delta_change = calculate_vote_delta_change(current_vote, new_vote)
          new_vote_delta = current_vote_delta + vote_delta_change

          # Call the voting function (this will handle creating/updating/removing votes)
          result =
            case new_vote do
              nil ->
                {:ok, :removed}

              vote_type ->
                Elektrine.Social.Votes.vote_on_message(user_id, message.id, vote_type)
            end

          case result do
            {:ok, _} ->
              # Update post_interactions with the new vote state and delta
              post_interactions =
                Map.put(socket.assigns.post_interactions, post_id, %{
                  liked: Map.get(current_state, :liked, false),
                  boosted: Map.get(current_state, :boosted, false),
                  like_delta: Map.get(current_state, :like_delta, 0),
                  boost_delta: Map.get(current_state, :boost_delta, 0),
                  vote: new_vote,
                  vote_delta: new_vote_delta
                })

              {:noreply, assign(socket, :post_interactions, post_interactions)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to vote")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process post")}
      end
    end
  end

  # Reddit-style voting for Lemmy comments
  def handle_event("vote_comment", %{"comment_id" => comment_id, "type" => vote_type}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to vote")}
    else
      case APHelpers.get_or_store_remote_post(comment_id) do
        {:ok, message} ->
          user_id = socket.assigns.current_user.id
          current_state = Map.get(socket.assigns.post_interactions, comment_id, %{})
          current_vote = Map.get(current_state, :vote, nil)
          current_vote_delta = Map.get(current_state, :vote_delta, 0)

          # Determine the new vote state
          new_vote =
            if current_vote == vote_type, do: nil, else: vote_type

          # Calculate the vote delta change for optimistic UI update
          vote_delta_change = calculate_vote_delta_change(current_vote, new_vote)
          new_vote_delta = current_vote_delta + vote_delta_change

          # Call the voting function
          result =
            case new_vote do
              nil ->
                {:ok, :removed}

              vote_type ->
                Elektrine.Social.Votes.vote_on_message(user_id, message.id, vote_type)
            end

          case result do
            {:ok, _} ->
              # Update post_interactions with the new vote state and delta
              post_interactions =
                Map.put(socket.assigns.post_interactions, comment_id, %{
                  liked: Map.get(current_state, :liked, false),
                  boosted: Map.get(current_state, :boosted, false),
                  like_delta: Map.get(current_state, :like_delta, 0),
                  boost_delta: Map.get(current_state, :boost_delta, 0),
                  vote: new_vote,
                  vote_delta: new_vote_delta
                })

              {:noreply, assign(socket, :post_interactions, post_interactions)}

            {:error, _} ->
              {:noreply, put_flash(socket, :error, "Failed to vote")}
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process comment")}
      end
    end
  end

  def handle_event("react_to_post", %{"post_id" => post_id, "emoji" => emoji}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to react")}
    else
      user_id = socket.assigns.current_user.id

      # Use single-arg version to fetch correct actor from object (important for comments)
      case APHelpers.get_or_store_remote_post(post_id) do
        {:ok, message} ->
          alias Elektrine.Messaging.Reactions

          # Check if user already has this reaction
          existing_reaction =
            Elektrine.Repo.get_by(
              Elektrine.Messaging.MessageReaction,
              message_id: message.id,
              user_id: user_id,
              emoji: emoji
            )

          if existing_reaction do
            # Remove the existing reaction
            case Reactions.remove_reaction(message.id, user_id, emoji) do
              {:ok, _} ->
                updated_reactions =
                  PostInteractions.update_post_reactions(
                    socket.assigns.post_reactions,
                    post_id,
                    %{emoji: emoji, user_id: user_id},
                    :remove
                  )

                {:noreply, assign(socket, :post_reactions, updated_reactions)}

              {:error, _} ->
                {:noreply, socket}
            end
          else
            # Add new reaction
            case Reactions.add_reaction(message.id, user_id, emoji) do
              {:ok, reaction} ->
                reaction = Elektrine.Repo.preload(reaction, [:user, :remote_actor])

                updated_reactions =
                  PostInteractions.update_post_reactions(
                    socket.assigns.post_reactions,
                    post_id,
                    reaction,
                    :add
                  )

                {:noreply, assign(socket, :post_reactions, updated_reactions)}

              {:error, :rate_limited} ->
                {:noreply, put_flash(socket, :error, "Slow down! You're reacting too fast")}

              {:error, _} ->
                {:noreply, socket}
            end
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process remote post")}
      end
    end
  end

  def handle_event("react_to_post", %{"message_id" => message_id, "emoji" => emoji}, socket) do
    if current_user_missing?(socket) do
      {:noreply, put_flash(socket, :error, "You must be signed in to react")}
    else
      user_id = socket.assigns.current_user.id

      case PostInteractions.resolve_message_for_interaction(message_id,
             actor_uri: socket.assigns[:remote_actor] && socket.assigns.remote_actor.uri
           ) do
        {:ok, message} ->
          alias Elektrine.Messaging.Reactions
          key = PostInteractions.interaction_key(message_id, message)

          existing_reaction =
            Elektrine.Repo.get_by(
              Elektrine.Messaging.MessageReaction,
              message_id: message.id,
              user_id: user_id,
              emoji: emoji
            )

          if existing_reaction do
            case Reactions.remove_reaction(message.id, user_id, emoji) do
              {:ok, _} ->
                updated_reactions =
                  PostInteractions.update_post_reactions(
                    socket.assigns.post_reactions,
                    key,
                    %{emoji: emoji, user_id: user_id},
                    :remove
                  )

                {:noreply, assign(socket, :post_reactions, updated_reactions)}

              {:error, _} ->
                {:noreply, socket}
            end
          else
            case Reactions.add_reaction(message.id, user_id, emoji) do
              {:ok, reaction} ->
                reaction = Elektrine.Repo.preload(reaction, [:user, :remote_actor])

                updated_reactions =
                  PostInteractions.update_post_reactions(
                    socket.assigns.post_reactions,
                    key,
                    reaction,
                    :add
                  )

                {:noreply, assign(socket, :post_reactions, updated_reactions)}

              {:error, :rate_limited} ->
                {:noreply, put_flash(socket, :error, "Slow down! You're reacting too fast")}

              {:error, _} ->
                {:noreply, socket}
            end
          end

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to process post")}
      end
    end
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
    threaded_replies = build_reply_tree(socket.assigns.replies, socket.assigns.post["id"], sort)

    {:noreply,
     socket
     |> assign(:comment_sort, sort)
     |> assign(:threaded_replies, threaded_replies)}
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

  defp format_activitypub_date(date), do: APHelpers.format_activitypub_date(date)
  defp get_collection_total_items(coll), do: APHelpers.get_collection_total(coll)
  defp get_follower_count(meta), do: APHelpers.get_follower_count(meta)
  defp format_join_date(date), do: APHelpers.format_join_date(date)

  defp load_post_interactions(posts, user_id),
    do: APHelpers.load_post_interactions(posts, user_id)

  defp get_or_store_remote_post(activitypub_id, actor_uri) do
    APHelpers.get_or_store_remote_post(activitypub_id, actor_uri)
  end

  # Build a tree structure from flat replies based on inReplyTo or Lemmy path
  defp build_reply_tree(replies, root_post_id, sort) do
    # Check if these are Lemmy comments (have _lemmy.path)
    has_lemmy_paths =
      Enum.any?(replies, fn reply ->
        get_in(reply, ["_lemmy", "path"]) != nil
      end)

    if has_lemmy_paths do
      build_lemmy_tree(replies, sort)
    else
      build_standard_tree(replies, root_post_id, sort)
    end
  end

  # Sort replies based on sort type
  defp sort_replies(replies, sort) do
    case sort do
      "hot" ->
        # Hot: combination of score and recency
        Enum.sort_by(replies, fn reply ->
          score = get_reply_score(reply)
          age_hours = get_reply_age_hours(reply)
          # Higher score and more recent = higher rank
          -(score / max(age_hours, 1))
        end)

      "top" ->
        # Top: highest score first
        Enum.sort_by(replies, &(-get_reply_score(&1)))

      "new" ->
        # New: most recent first
        Enum.sort_by(
          replies,
          fn reply ->
            reply["published"] || ""
          end,
          :desc
        )

      "old" ->
        # Old: oldest first
        Enum.sort_by(
          replies,
          fn reply ->
            reply["published"] || ""
          end,
          :asc
        )

      _ ->
        replies
    end
  end

  defp get_reply_score(reply) do
    likes = APHelpers.get_collection_total(reply["likes"]) || 0
    dislikes = APHelpers.get_collection_total(reply["dislikes"]) || 0
    likes - dislikes
  end

  defp get_reply_age_hours(reply) do
    case reply["published"] do
      nil ->
        1

      date_string ->
        case DateTime.from_iso8601(date_string) do
          {:ok, datetime, _} ->
            DateTime.diff(DateTime.utc_now(), datetime, :hour) |> max(1)

          _ ->
            1
        end
    end
  end

  # Build tree from standard ActivityPub inReplyTo
  defp build_standard_tree(replies, root_post_id, sort) do
    # Group replies by their parent (inReplyTo)
    children_map =
      Enum.group_by(replies, fn reply ->
        reply["inReplyTo"]
      end)

    reply_ids =
      replies
      |> Enum.map(& &1["id"])
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    root_parent_ids = [root_post_id, nil, ""]

    explicit_roots =
      root_parent_ids
      |> Enum.flat_map(&Map.get(children_map, &1, []))

    # Some platforms return an inReplyTo URI that does not exactly match the
    # post ID we loaded. Treat replies whose parent is unknown as top-level so
    # they remain visible instead of disappearing until a second refresh.
    orphan_roots =
      replies
      |> Enum.filter(fn reply ->
        parent_id = reply["inReplyTo"]

        parent_id not in root_parent_ids &&
          (is_nil(parent_id) || parent_id == "" || !MapSet.member?(reply_ids, parent_id))
      end)

    root_replies =
      (explicit_roots ++ orphan_roots)
      |> Enum.uniq_by(&reply_identity_key/1)
      |> sort_replies(sort)

    Enum.map(root_replies, fn reply ->
      %{
        reply: reply,
        depth: 0,
        children: build_children(children_map, reply["id"], 1, sort)
      }
    end)
  end

  # Build tree from Lemmy path-based threading
  # Path format: "0.commentId" for top-level, "0.parentId.childId" for nested
  # Also handles local replies that use inReplyTo instead of Lemmy paths
  defp build_lemmy_tree(replies, sort) do
    # Separate replies with Lemmy paths from local replies (which use inReplyTo)
    {lemmy_replies, local_replies} =
      Enum.split_with(replies, fn reply ->
        get_in(reply, ["_lemmy", "path"]) != nil
      end)

    # Parse paths and sort by path to ensure parents come before children
    sorted_lemmy_replies =
      Enum.sort_by(lemmy_replies, fn reply ->
        path = get_in(reply, ["_lemmy", "path"]) || "0"
        # Sort by path length first (parents before children), then by path value
        parts = String.split(path, ".")
        {length(parts), path}
      end)

    # Build map from Lemmy comment ID to ActivityPub ID
    # The comment ID is the last part of the path
    id_map =
      Map.new(sorted_lemmy_replies, fn reply ->
        path = get_in(reply, ["_lemmy", "path"]) || "0"
        parts = String.split(path, ".")
        comment_id = List.last(parts)
        {comment_id, reply["id"]}
      end)

    # Group Lemmy replies by parent (second-to-last path element, or "0" for top-level)
    lemmy_children_map =
      Enum.group_by(sorted_lemmy_replies, fn reply ->
        path = get_in(reply, ["_lemmy", "path"]) || "0"
        parts = String.split(path, ".")

        case parts do
          ["0", _comment_id] ->
            :root

          ["0" | rest] when length(rest) >= 2 ->
            # Get the parent comment ID (second-to-last element)
            parent_id = Enum.at(rest, length(rest) - 2)
            Map.get(id_map, parent_id, :root)

          _ ->
            :root
        end
      end)

    # Group local replies by their inReplyTo (parent's ActivityPub ID)
    local_children_map =
      Enum.group_by(local_replies, fn reply ->
        reply["inReplyTo"] || :root
      end)

    # Merge the two children maps
    children_map =
      Map.merge(lemmy_children_map, local_children_map, fn _key, lemmy, local ->
        lemmy ++ local
      end)

    # Build tree starting from root
    build_lemmy_children(children_map, :root, id_map, 0, sort)
  end

  defp build_lemmy_children(children_map, parent_key, id_map, depth, sort) do
    children = Map.get(children_map, parent_key, [])
    sorted_children = sort_replies(children, sort)

    Enum.map(sorted_children, fn reply ->
      nested_children = build_lemmy_children(children_map, reply["id"], id_map, depth + 1, sort)

      %{
        reply: reply,
        depth: depth,
        children: nested_children
      }
    end)
  end

  defp build_children(children_map, parent_id, depth, sort) do
    children = Map.get(children_map, parent_id, [])
    sorted_children = sort_replies(children, sort)

    Enum.map(sorted_children, fn reply ->
      nested_children = build_children(children_map, reply["id"], depth + 1, sort)

      %{
        reply: reply,
        depth: depth,
        children: nested_children
      }
    end)
  end

  defp extract_username_from_uri(uri) when is_binary(uri) do
    cond do
      String.contains?(uri, "/u/") ->
        uri |> String.split("/u/") |> List.last() |> String.split("/") |> List.first()

      String.contains?(uri, "/users/") ->
        uri |> String.split("/users/") |> List.last() |> String.split("/") |> List.first()

      String.contains?(uri, "/@") ->
        uri |> String.split("/@") |> List.last() |> String.split("/") |> List.first()

      true ->
        uri |> URI.parse() |> Map.get(:path, "") |> String.split("/") |> List.last()
    end
  end

  defp extract_username_from_uri(_), do: "unknown"

  # Convert cached messages (local and federated) to ActivityPub-like format for display
  # in the reply tree.
  defp convert_cached_messages_to_ap_format(messages) do
    Enum.map(messages, fn msg ->
      base_url = ElektrineWeb.Endpoint.url()

      {actor_uri, local_user, is_local_reply} =
        cond do
          Ecto.assoc_loaded?(msg.sender) && msg.sender ->
            {"#{base_url}/users/#{msg.sender.username}", msg.sender, true}

          Ecto.assoc_loaded?(msg.remote_actor) && msg.remote_actor && msg.remote_actor.uri ->
            {msg.remote_actor.uri, nil, false}

          Ecto.assoc_loaded?(msg.remote_actor) && msg.remote_actor ->
            {"https://#{msg.remote_actor.domain}/users/#{msg.remote_actor.username}", nil, false}

          true ->
            {nil, nil, false}
        end

      %{
        "id" => msg.activitypub_id || "#{base_url}/messages/#{msg.id}",
        "type" => "Note",
        "attributedTo" => actor_uri,
        "content" => msg.content,
        "published" => NaiveDateTime.to_iso8601(msg.inserted_at) <> "Z",
        "inReplyTo" => Map.get(msg, :parent_activitypub_id),
        "likes" => %{"totalItems" => msg.like_count || 0},
        "_local" => is_local_reply,
        "_local_user" => local_user,
        "_local_message_id" => msg.id
      }
    end)
  end

  # Fetch cached replies and merge with remote replies.
  defp merge_local_replies(remote_replies, post_id) do
    seed_activitypub_ids =
      [post_id | Enum.map(remote_replies, & &1["id"])]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    cached_messages = collect_cached_replies(seed_activitypub_ids)

    if Enum.empty?(cached_messages) do
      remote_replies
    else
      cached_ap_format = convert_cached_messages_to_ap_format(cached_messages)

      (remote_replies ++ cached_ap_format)
      |> Enum.uniq_by(&reply_identity_key/1)
    end
  end

  defp collect_cached_replies(activitypub_ids) do
    do_collect_cached_replies(activitypub_ids, MapSet.new())
  end

  defp do_collect_cached_replies(activitypub_ids, seen_message_ids) do
    sanitized_ids =
      activitypub_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if Enum.empty?(sanitized_ids) do
      []
    else
      fetched = Elektrine.Messaging.get_cached_replies_to_activitypub_ids(sanitized_ids)

      new_messages =
        Enum.reject(fetched, fn message ->
          MapSet.member?(seen_message_ids, message.id)
        end)

      if Enum.empty?(new_messages) do
        []
      else
        next_ids =
          new_messages
          |> Enum.map(& &1.activitypub_id)
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()

        next_seen_ids =
          Enum.reduce(new_messages, seen_message_ids, fn message, acc ->
            MapSet.put(acc, message.id)
          end)

        new_messages ++ do_collect_cached_replies(next_ids, next_seen_ids)
      end
    end
  end

  defp reply_identity_key(%{"id" => id}) when is_binary(id), do: id

  defp reply_identity_key(reply) when is_map(reply) do
    attributed_to = reply["attributedTo"] || "unknown"
    published = reply["published"] || "unknown"
    content_hash = :erlang.phash2(reply["content"] || "")
    "#{attributed_to}:#{published}:#{content_hash}"
  end

  defp recent_replies_for_preview(replies, root_post_id, limit \\ 3)

  defp recent_replies_for_preview(replies, root_post_id, limit)
       when is_list(replies) and is_binary(root_post_id) do
    replies
    |> Enum.filter(fn reply -> is_map(reply) and reply["inReplyTo"] == root_post_id end)
    |> Enum.sort_by(fn reply -> reply["published"] || "" end, :desc)
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  defp recent_replies_for_preview(_, _, _), do: []

  defp resolve_comment_target_message(comment_id, replies) when is_binary(comment_id) do
    case local_message_id_for_reply(replies, comment_id) do
      local_message_id when is_integer(local_message_id) ->
        case Elektrine.Repo.get(Elektrine.Messaging.Message, local_message_id) do
          %Elektrine.Messaging.Message{} = message ->
            {:ok, message}

          _ ->
            APHelpers.get_or_store_remote_post(comment_id)
        end

      _ ->
        APHelpers.get_or_store_remote_post(comment_id)
    end
  end

  defp resolve_comment_target_message(_, _), do: {:error, :invalid_comment}

  defp local_message_id_for_reply(replies, comment_id) when is_list(replies) do
    Enum.find_value(replies, fn reply ->
      if is_map(reply) && reply["id"] == comment_id do
        case reply["_local_message_id"] do
          id when is_integer(id) -> id
          _ -> nil
        end
      end
    end)
  end

  defp local_message_id_for_reply(_, _), do: nil

  defp current_user_missing?(socket), do: is_nil(socket.assigns[:current_user])
end
