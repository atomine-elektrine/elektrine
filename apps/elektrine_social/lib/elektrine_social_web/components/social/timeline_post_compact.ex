defmodule ElektrineSocialWeb.Components.Social.TimelinePostCompact do
  @moduledoc false

  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]
  import ElektrineWeb.CoreComponents
  import ElektrineWeb.HtmlHelpers

  alias ElektrineSocialWeb.Components.Social.PostUtilities
  alias ElektrineSocialWeb.Components.Social.TimelinePostCard

  def render_compact_layout(assigns) do
    post = assigns.post
    is_reply = PostUtilities.reply?(post)
    is_gallery_post = PostUtilities.gallery_post?(post)

    {display_like_count, display_comment_count} =
      PostUtilities.get_display_counts(post, assigns.lemmy_counts, assigns.post_replies)

    # Compact cards should use the same title fallback chain as Lemmy cards.
    title = TimelinePostCard.resolve_federated_title(post)

    image_urls = PostUtilities.filter_image_urls(post.media_urls || [])
    has_image = !Enum.empty?(image_urls)
    thumbnail = if has_image, do: thumbnail_url(hd(image_urls), 64), else: nil

    card_post_path = TimelinePostCard.card_post_path(post, assigns.source)

    assigns =
      assigns
      |> assign(:is_reply, is_reply)
      |> assign(:is_gallery_post, is_gallery_post)
      |> assign(:display_like_count, display_like_count)
      |> assign(:display_comment_count, display_comment_count)
      |> assign(:title, title)
      |> assign(:has_image, has_image)
      |> assign(:thumbnail, thumbnail)
      |> assign(:card_post_path, card_post_path)
      |> assign(:card_post_external?, TimelinePostCard.external_url?(card_post_path))

    ~H"""
    <div
      id={"#{@id_prefix}-compact-post-#{@post.id}"}
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
      
    <!-- Thumbnail -->
      <%= if @has_image do %>
        <div class="w-16 h-16 flex-shrink-0 rounded overflow-hidden">
          <img src={@thumbnail} alt="" class="w-full h-full object-cover" loading="lazy" />
        </div>
      <% end %>

      <div class="flex-1 min-w-0">
        <!-- Title or content preview -->
        <%= if @title do %>
          <.link
            href={if @card_post_external?, do: @card_post_path, else: nil}
            navigate={if @card_post_external?, do: nil, else: @card_post_path}
            class="block"
          >
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
            <span
              id={"#{@id_prefix}-compact-post-#{@post.id}-like-count"}
              phx-hook="AnimatedCount"
              phx-update="ignore"
              data-count={@display_like_count || 0}
            >
              {@display_like_count || 0}
            </span>
          </span>
          <span class="flex items-center gap-1">
            <.icon name="hero-chat-bubble-left" class="w-3 h-3" />
            <span
              id={"#{@id_prefix}-compact-post-#{@post.id}-comment-count"}
              phx-hook="AnimatedCount"
              phx-update="ignore"
              data-count={@display_comment_count || 0}
            >
              {@display_comment_count || 0}
            </span>
          </span>
          <span>·</span>
          <.link navigate={@card_post_path} class="hover:text-primary">
            Open
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
