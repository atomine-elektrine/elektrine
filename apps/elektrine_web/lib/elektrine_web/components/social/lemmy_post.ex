defmodule ElektrineWeb.Components.Social.LemmyPost do
  @moduledoc """
  Renders posts in Lemmy/Reddit style - compact layout with vote column, thumbnail, and threaded comments.
  Used for posts from Lemmy instances and other community-focused platforms.

  NOTE: This component is being deprecated in favor of TimelinePost with layout={:lemmy}.
  New code should use TimelinePost directly.
  """
  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]
  import ElektrineWeb.CoreComponents
  import ElektrineWeb.HtmlHelpers

  alias ElektrineWeb.Components.Social.PostUtilities

  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :timezone, :string, default: "UTC"
  attr :post_interactions, :map, default: %{}
  attr :user_likes, :map, default: %{}
  attr :user_downvotes, :map, default: %{}
  attr :lemmy_counts, :map, default: nil
  attr :replies, :list, default: []
  attr :on_like, :string, default: "like_post"
  attr :on_unlike, :string, default: "unlike_post"
  attr :on_downvote, :string, default: "downvote_post"
  attr :on_undownvote, :string, default: "undownvote_post"
  attr :on_navigate, :string, default: "navigate_to_remote_post"
  attr :on_image_click, :string, default: nil
  attr :reactions, :list, default: []
  attr :on_react, :string, default: "react_to_post"
  attr :source, :string, default: "timeline"

  def lemmy_post(assigns) do
    # Get interaction state - check both post_interactions and user_likes
    post_id = assigns.post.activitypub_id || to_string(assigns.post.id)

    post_state =
      Map.get(assigns.post_interactions, post_id, %{liked: false, downvoted: false, like_delta: 0})

    # Check user_likes/user_downvotes (keyed by integer post.id) with fallback to post_interactions
    # This allows both timeline (uses user_likes) and discussions (uses post_interactions) to work
    is_liked =
      case Map.fetch(assigns.user_likes, assigns.post.id) do
        {:ok, val} -> val
        :error -> Map.get(post_state, :liked, false)
      end

    is_downvoted =
      case Map.fetch(assigns.user_downvotes, assigns.post.id) do
        {:ok, val} -> val
        :error -> Map.get(post_state, :downvoted, false)
      end

    # Calculate like count - use Lemmy API score if available, otherwise use local count
    # Score = upvotes - downvotes, which goes +1 on upvote, -1 on downvote
    # Always apply like_delta for optimistic updates from user voting
    like_delta = Map.get(post_state, :like_delta, 0)

    base_count =
      if assigns.lemmy_counts do
        assigns.lemmy_counts.score
      else
        assigns.post.like_count || 0
      end

    like_count = base_count + like_delta

    # Check for image thumbnail - filter to actual image URLs
    image_urls =
      (assigns.post.media_urls || [])
      |> Enum.filter(fn url ->
        # Must look like an image URL (has image extension or known image host pattern)
        is_binary(url) &&
          (String.match?(url, ~r/\.(jpe?g|png|gif|webp|svg|bmp|avif)(\?.*)?$/i) ||
             String.match?(
               url,
               ~r/(\/media\/|\/images\/|\/uploads\/|\/pictrs\/|i\.imgur|pbs\.twimg|i\.redd\.it)/i
             ))
      end)

    has_image = !Enum.empty?(image_urls)
    # Use thumbnail version for small display (80x80)
    image_url = if has_image, do: thumbnail_url(hd(image_urls), 96), else: nil

    # Get title from metadata if available
    title = get_in(assigns.post.media_metadata || %{}, ["name"])

    # Get community info
    community_uri = get_in(assigns.post.media_metadata || %{}, ["community_actor_uri"])

    # Check for external link submission (Lemmy link posts)
    # First check metadata, then fallback to activitypub_url if it's external, then extract from content
    external_link =
      get_in(assigns.post.media_metadata || %{}, ["external_link"]) ||
        detect_external_link(assigns.post)

    # Reply count - use Lemmy API counts if available, otherwise use metadata or local replies
    local_reply_count = length(assigns.replies)

    remote_reply_count =
      if assigns.lemmy_counts do
        assigns.lemmy_counts.comments
      else
        get_in(assigns.post.media_metadata || %{}, ["remote_engagement", "replies"]) || 0
      end

    reply_count = max(local_reply_count, remote_reply_count)

    # Format reactions for display
    current_user_id = if assigns.current_user, do: assigns.current_user.id, else: nil
    formatted_reactions = format_reactions(assigns.reactions, current_user_id)

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

    # Use stable ID based on post ID - don't use System.unique_integer as it changes on every render
    # causing LiveView to treat it as a new element and causing layout reflow
    assigns = assign(assigns, :unique_id, "lemmy-post-#{assigns.post.id}")

    ~H"""
    <article
      id={@unique_id}
      class="card glass-card border border-base-300 rounded-lg overflow-hidden hover:shadow-md transition-all relative z-0"
      data-post-id={@post.id}
      data-source={@source}
      phx-hook="PostClick"
      data-click-event={@on_navigate}
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
            <!-- Link submission thumbnail -->
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
          phx-click={@on_navigate}
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
              {raw(render_content_preview(@post.content, @post))}
            </div>
          <% end %>
          
    <!-- External link domain for link submissions -->
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
            <!-- Link preview for content URLs -->
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
                {extract_community_name(@community_uri)}
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
              <!-- Existing reactions -->
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
              
    <!-- Quick reaction buttons for logged-in users -->
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
    </article>
    """
  end

  # Delegate helper functions to PostUtilities
  defp extract_community_name(uri), do: PostUtilities.extract_community_name(uri)
  defp render_content_preview(content, source) do
    PostUtilities.render_content_preview(content, PostUtilities.get_instance_domain(source))
  end
  defp detect_external_link(post), do: PostUtilities.detect_external_link(post)

  defp format_reactions(reactions, user_id),
    do: PostUtilities.format_reactions(reactions, user_id)
end
