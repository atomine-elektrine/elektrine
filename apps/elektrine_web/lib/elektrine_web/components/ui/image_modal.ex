defmodule ElektrineWeb.Components.UI.ImageModal do
  @moduledoc """
  Full-size image modal with avatar, username, and post context.
  Supports both local users and remote ActivityPub actors.
  """
  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]
  import ElektrineWeb.CoreComponents
  import ElektrineWeb.Components.User.Avatar
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.HtmlHelpers

  attr :show, :boolean, default: false
  attr :image_url, :string, default: nil
  attr :images, :list, default: []
  attr :image_index, :integer, default: 0
  attr :post, :map, default: nil
  attr :post_url, :string, default: nil
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "24h"
  attr :user_statuses, :map, default: %{}
  attr :is_liked, :boolean, default: false
  attr :like_count, :integer, default: 0
  attr :current_user, :map, default: nil

  def image_modal(assigns) do
    # Generate unique ID based on image URL to ensure hook remounts properly
    modal_id = "image-modal-#{:erlang.phash2(assigns.image_url || "default")}"
    assigns = assign(assigns, :modal_id, modal_id)

    ~H"""
    <%= if @show do %>
      <div class="modal modal-open" phx-hook="ImageModal" id={@modal_id}>
        <div class="modal-box max-w-7xl p-0 relative">
          <!-- Close button -->
          <button
            type="button"
            phx-click="close_image_modal"
            class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2 z-10 bg-base-100/80 backdrop-blur-sm hover:bg-base-100"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
          
    <!-- Image counter -->
          <%= if length(@images) > 1 do %>
            <div class="absolute top-2 left-1/2 -translate-x-1/2 z-10 badge badge-neutral bg-base-100/80 backdrop-blur-sm">
              {@image_index + 1} / {length(@images)}
            </div>
          <% end %>

          <% # Determine post ID for like actions (used by image click and button)
          post_id_for_like =
            cond do
              @post && Map.get(@post, :id) && is_integer(@post.id) -> @post.id
              @post && Map.get(@post, :activitypub_id) -> @post.activitypub_id
              true -> nil
            end

          # Check if sender is actually loaded (not Ecto.Association.NotLoaded)
          sender_loaded = @post && Map.get(@post, :sender) && Ecto.assoc_loaded?(@post.sender)

          remote_actor_loaded =
            @post && Map.get(@post, :remote_actor) && Ecto.assoc_loaded?(@post.remote_actor) %>
          
    <!-- User Info Header -->
          <%= if sender_loaded || remote_actor_loaded do %>
            <div class="absolute top-2 left-2 z-10 flex items-center gap-2 bg-base-100/80 backdrop-blur-sm rounded-full px-3 py-2">
              <%= if sender_loaded do %>
                <.link
                  href={"/#{@post.sender.handle || @post.sender.username}"}
                  class="w-8 h-8 flex-shrink-0"
                >
                  <.user_avatar user={@post.sender} size="xs" user_statuses={@user_statuses} />
                </.link>
                <div class="min-w-0">
                  <.link
                    href={"/#{@post.sender.handle || @post.sender.username}"}
                    class="font-medium hover:underline hover:text-primary transition-colors text-left text-sm"
                  >
                    <.username_with_effects
                      user={@post.sender}
                      display_name={true}
                      verified_size="xs"
                    />
                  </.link>
                </div>
              <% else %>
                <!-- Remote actor -->
                <.link
                  href={"/remote/#{@post.remote_actor.username}@#{@post.remote_actor.domain}"}
                  class="w-8 h-8 flex-shrink-0"
                >
                  <%= if @post.remote_actor.avatar_url do %>
                    <img
                      src={@post.remote_actor.avatar_url}
                      alt={@post.remote_actor.username}
                      class="w-8 h-8 rounded-full object-cover"
                    />
                  <% else %>
                    <div class="w-8 h-8 rounded-full bg-base-300 flex items-center justify-center">
                      <.icon name="hero-user" class="w-4 h-4" />
                    </div>
                  <% end %>
                </.link>
                <div class="min-w-0">
                  <.link
                    href={"/remote/#{@post.remote_actor.username}@#{@post.remote_actor.domain}"}
                    class="font-medium hover:underline hover:text-primary transition-colors text-left text-sm"
                  >
                    {raw(
                      render_display_name_with_emojis(
                        @post.remote_actor.display_name || @post.remote_actor.username,
                        @post.remote_actor.domain
                      )
                    )}
                  </.link>
                  <div class="text-xs opacity-60">
                    @{@post.remote_actor.username}@{@post.remote_actor.domain}
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
          
    <!-- Media container -->
          <div class="relative bg-base-200">
            <!-- Previous button -->
            <%= if length(@images) > 1 do %>
              <button
                type="button"
                phx-click="prev_image"
                class="btn btn-circle btn-ghost absolute left-2 top-1/2 -translate-y-1/2 z-10 bg-base-100/80 backdrop-blur-sm hover:bg-base-100"
              >
                <.icon name="hero-chevron-left" class="w-6 h-6" />
              </button>
            <% end %>
            
    <!-- Next button -->
            <%= if length(@images) > 1 do %>
              <button
                type="button"
                phx-click="next_image"
                class="btn btn-circle btn-ghost absolute right-2 top-1/2 -translate-y-1/2 z-10 bg-base-100/80 backdrop-blur-sm hover:bg-base-100"
              >
                <.icon name="hero-chevron-right" class="w-6 h-6" />
              </button>
            <% end %>
            
    <!-- Media (Image, Video, or Audio) -->
            <%= cond do %>
              <% is_video_url?(@image_url) -> %>
                <video
                  src={@image_url}
                  controls
                  preload="metadata"
                  class="w-full h-auto max-h-[80vh]"
                >
                  Your browser does not support the video tag.
                </video>
              <% is_audio_url?(@image_url) -> %>
                <div class="p-8 bg-base-200 flex flex-col items-center justify-center min-h-[40vh]">
                  <.icon name="hero-musical-note" class="w-24 h-24 opacity-30 mb-6" />
                  <audio
                    src={@image_url}
                    controls
                    preload="metadata"
                    class="w-full max-w-lg"
                  >
                    Your browser does not support the audio tag.
                  </audio>
                </div>
              <% true -> %>
                <%= if @current_user && post_id_for_like do %>
                  <img
                    src={@image_url}
                    alt="Full size image"
                    class="w-full h-auto max-h-[80vh] object-contain cursor-pointer"
                    phx-click="toggle_modal_like"
                    phx-value-post_id={post_id_for_like}
                  />
                <% else %>
                  <img
                    src={@image_url}
                    alt="Full size image"
                    class="w-full h-auto max-h-[80vh] object-contain"
                  />
                <% end %>
            <% end %>
          </div>
          
    <!-- Post Content Footer -->
          <% # Derive post URL if not provided
          # Check for remote_actor to determine if this is a federated post
          has_remote_actor =
            @post && Map.get(@post, :remote_actor) &&
              (is_struct(@post.remote_actor) ||
                 (is_map(@post.remote_actor) && @post.remote_actor != %{}))

          derived_post_url =
            cond do
              @post_url ->
                @post_url

              # Federated post with activitypub_id - use remote post URL
              has_remote_actor && @post && Map.get(@post, :activitypub_id) ->
                "/remote/post/#{URI.encode_www_form(@post.activitypub_id)}"

              # Local timeline post with id
              @post && Map.get(@post, :id) && is_integer(@post.id) && !has_remote_actor ->
                "/timeline/post/#{@post.id}"

              # Fallback for activitypub_id
              @post && Map.get(@post, :activitypub_id) ->
                "/remote/post/#{URI.encode_www_form(@post.activitypub_id)}"

              true ->
                nil
            end

          show_footer =
            (@post && @post.content && @post.content != "") || derived_post_url || @current_user %>
          <%= if show_footer do %>
            <div class="p-4 bg-base-200 border-t border-base-300">
              <%= if @post && @post.content && @post.content != "" do %>
                <div class="text-sm break-words post-content mb-3">
                  <%= if has_remote_actor && @post.remote_actor do %>
                    {raw(
                      render_remote_post_content(
                        String.trim(@post.content),
                        @post.remote_actor.domain
                      )
                    )}
                  <% else %>
                    {raw(make_content_safe_with_links(String.trim(@post.content)))}
                  <% end %>
                </div>
              <% end %>
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-3">
                  <!-- Like Button -->
                  <%= if @current_user && post_id_for_like do %>
                    <button
                      type="button"
                      phx-click="toggle_modal_like"
                      phx-value-post_id={post_id_for_like}
                      class="btn btn-ghost btn-sm gap-1"
                    >
                      <%= if @is_liked do %>
                        <.icon name="hero-heart-solid" class="w-4 h-4 text-error" />
                      <% else %>
                        <.icon name="hero-heart" class="w-4 h-4" />
                      <% end %>
                      <span>{@like_count}</span>
                    </button>
                  <% else %>
                    <div class="flex items-center gap-1 text-sm opacity-70">
                      <.icon name="hero-heart" class="w-4 h-4" />
                      <span>{@like_count}</span>
                    </div>
                  <% end %>
                  <!-- Timestamp -->
                  <%= if @post && @post.inserted_at do %>
                    <div class="text-xs opacity-70">
                      <.local_time
                        datetime={@post.inserted_at}
                        format="relative"
                        timezone={@timezone}
                        time_format={@time_format}
                      />
                    </div>
                  <% end %>
                </div>
                <%= if derived_post_url do %>
                  <.link navigate={derived_post_url} class="btn btn-ghost btn-xs gap-1">
                    <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" /> View Post
                  </.link>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
        <form method="dialog" class="modal-backdrop" phx-click="close_image_modal">
          <button>close</button>
        </form>
      </div>
    <% end %>
    """
  end

  defp is_video_url?(nil), do: false

  defp is_video_url?(url) when is_binary(url) do
    String.match?(url, ~r/\.(mp4|webm|ogv|mov|avi|mkv)(\?.*)?$/i)
  end

  defp is_audio_url?(nil), do: false

  defp is_audio_url?(url) when is_binary(url) do
    String.match?(url, ~r/\.(mp3|wav|ogg|m4a|aac|flac)(\?.*)?$/i)
  end
end
