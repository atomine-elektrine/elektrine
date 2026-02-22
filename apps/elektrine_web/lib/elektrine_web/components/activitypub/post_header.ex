defmodule ElektrineWeb.Components.ActivityPub.PostHeader do
  @moduledoc false
  use Phoenix.Component
  import ElektrineWeb.CoreComponents
  import ElektrineWeb.HtmlHelpers
  import Phoenix.HTML

  attr :post, :map, required: true
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "12"
  attr :user_statuses, :map, default: %{}

  def post_author(assigns) do
    # Generate remote profile path: /remote/username@domain
    assigns =
      if assigns[:post].federated && assigns[:post].remote_actor do
        remote_profile_path =
          "/remote/#{assigns.post.remote_actor.username}@#{assigns.post.remote_actor.domain}"

        assign(assigns, :remote_profile_path, remote_profile_path)
      else
        assigns
      end

    ~H"""
    <%= if @post.federated && @post.remote_actor do %>
      <!-- Remote federated post header -->
      <div class="flex items-center gap-3 mb-3">
        <.link navigate={@remote_profile_path} class="flex-shrink-0">
          <div class="w-10 h-10 rounded-full overflow-hidden bg-base-200">
            <%= if @post.remote_actor.avatar_url do %>
              <img
                src={@post.remote_actor.avatar_url}
                alt={@post.remote_actor.username}
                class="w-full h-full object-cover"
              />
            <% else %>
              <div class="w-full h-full flex items-center justify-center text-lg font-bold">
                {String.first(@post.remote_actor.username) |> String.upcase()}
              </div>
            <% end %>
          </div>
        </.link>
        <div class="flex-1 min-w-0 flex flex-col justify-center">
          <div class="flex items-center gap-2">
            <.link
              navigate={@remote_profile_path}
              class="font-medium truncate hover:text-secondary transition-colors"
            >
              {raw(
                render_display_name_with_emojis(
                  @post.remote_actor.display_name || @post.remote_actor.username,
                  @post.remote_actor.domain
                )
              )}
            </.link>
            <span class="badge badge-xs badge-purple flex-shrink-0">
              <.icon name="hero-globe-americas" class="w-2.5 h-2.5 mr-0.5" /> Federated
            </span>
          </div>
          <div class="text-sm opacity-70 truncate">
            @{@post.remote_actor.username}@{@post.remote_actor.domain}
          </div>
        </div>
      </div>
    <% else %>
      <!-- Local post header -->
      <div class="flex items-center gap-3 mb-3">
        <div class="flex-shrink-0">
          <button
            phx-click="navigate_to_profile"
            phx-value-handle={@post.sender.handle || @post.sender.username}
            class="w-10 h-10"
            type="button"
          >
            <%= if @post.sender.avatar do %>
              <img
                src={@post.sender.avatar}
                alt={@post.sender.username}
                class="w-10 h-10 rounded-full"
              />
            <% else %>
              <div class="w-10 h-10 rounded-full bg-base-200 flex items-center justify-center font-bold">
                {String.first(@post.sender.username) |> String.upcase()}
              </div>
            <% end %>
          </button>
        </div>
        <div class="flex-1 min-w-0 flex flex-col justify-center">
          <button
            phx-click="navigate_to_profile"
            phx-value-handle={@post.sender.handle || @post.sender.username}
            class="font-medium hover:text-secondary transition-colors text-left truncate block"
            type="button"
          >
            {@post.sender.display_name || @post.sender.username}
          </button>
          <div class="text-sm opacity-70 truncate">
            @{@post.sender.handle || @post.sender.username}
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
