defmodule ElektrineWeb.Components.Social.FediverseFollow do
  @moduledoc """
  Reusable component for following users and communities from the fediverse.
  Displays an input field with preview and submit functionality.

  Supports:
  - Users: user@mastodon.social, @user@pixelfed.social
  - Communities: !community@lemmy.ml

  Compatible platforms: Mastodon, Pixelfed, Pleroma, Lemmy, Kbin, Misskey
  """
  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]
  import ElektrineWeb.CoreComponents
  import ElektrineWeb.HtmlHelpers, only: [render_display_name_with_emojis: 2]

  @doc """
  Renders a fediverse follow box with input, preview, and submit button.

  ## Attributes

  * `:loading` - Whether the remote user/community is being fetched
  * `:preview` - The remote actor preview data (nil if not yet fetched)
  * `:on_submit` - Event name for form submission (default: "follow_remote_user")
  * `:on_preview` - Event name for preview/change (default: "preview_remote_user")
  * `:input_name` - The name attribute for the input field (default: "remote_handle")
  * `:placeholder` - Input placeholder text
  * `:show_card` - Whether to wrap in a card container (default: true)
  * `:title` - Title text (default: "Follow Fediverse")
  * `:show_help` - Whether to show help text below (default: true)
  * `:debounce` - Debounce time in ms for preview (default: 500)

  ## Examples

      <!-- Basic usage in a sidebar -->
      <.fediverse_follow
        loading={@remote_user_loading}
        preview={@remote_user_preview}
      />

      <!-- Without card wrapper -->
      <.fediverse_follow
        loading={@remote_user_loading}
        preview={@remote_user_preview}
        show_card={false}
        title="Search Fediverse"
      />

      <!-- Custom events -->
      <.fediverse_follow
        loading={@fedi_loading}
        preview={@fedi_preview}
        on_submit="do_follow"
        on_preview="search_fediverse"
      />
  """
  attr :loading, :boolean, default: false
  attr :preview, :map, default: nil
  attr :on_submit, :string, default: "follow_remote_user"
  attr :on_preview, :string, default: "preview_remote_user"
  attr :input_name, :string, default: "remote_handle"
  attr :placeholder, :string, default: "user@mastodon.social or !community@lemmy.ml"
  attr :show_card, :boolean, default: true
  attr :title, :string, default: "Follow Fediverse"
  attr :show_help, :boolean, default: true
  attr :debounce, :integer, default: 500

  def fediverse_follow(assigns) do
    if assigns.show_card do
      render_with_card(assigns)
    else
      render_content(assigns)
    end
  end

  defp render_with_card(assigns) do
    ~H"""
    <div class="card glass-card shadow-lg">
      <div class="card-body p-4">
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-globe-americas" class="w-4 h-4 text-purple-600" />
          <h3 class="font-semibold text-sm">{@title}</h3>
        </div>
        {render_form(assigns)}
      </div>
    </div>
    """
  end

  defp render_content(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-2 mb-3">
        <.icon name="hero-globe-americas" class="w-4 h-4 text-purple-600" />
        <h3 class="font-semibold text-sm">{@title}</h3>
      </div>
      {render_form(assigns)}
    </div>
    """
  end

  defp render_form(assigns) do
    # Generate a unique ID for the input to support multiple instances
    input_id = "fediverse-follow-input-#{:erlang.phash2(assigns.on_submit)}"
    assigns = assign(assigns, :input_id, input_id)

    ~H"""
    <form phx-submit={@on_submit} phx-change={@on_preview} class="space-y-2">
      <input
        type="text"
        id={@input_id}
        name={@input_name}
        placeholder={@placeholder}
        class="input input-sm input-bordered w-full"
        phx-debounce={@debounce}
        phx-update="ignore"
        required
      />

      <%= if @loading do %>
        <div class="py-2 flex justify-center">
          <.spinner size="sm" />
        </div>
      <% end %>

      <%= if @preview do %>
        <.actor_preview actor={@preview} />
      <% end %>

      <button
        type="submit"
        class="btn btn-secondary btn-sm w-full"
        disabled={@loading || !@preview}
      >
        <.icon
          name={
            if @preview && @preview.actor_type == "Group", do: "hero-users", else: "hero-user-plus"
          }
          class="w-4 h-4 mr-1"
        />
        {if @preview && @preview.actor_type == "Group", do: "Follow Community", else: "Follow"}
      </button>
    </form>

    <%= if @show_help do %>
      <p class="text-[10px] opacity-60 mt-2">
        <strong>Communities:</strong> !community@lemmy.ml<br />
        <strong>Users:</strong> user@mastodon.social<br />
        <span class="opacity-50">Lemmy, Kbin, Mastodon, Pixelfed, Pleroma</span>
      </p>
    <% end %>
    """
  end

  @doc """
  Renders a preview card for a remote actor (user or community).
  """
  attr :actor, :map, required: true

  def actor_preview(assigns) do
    ~H"""
    <div class="card glass-card shadow-sm">
      <div class="card-body p-3">
        <div class="flex items-center gap-3">
          <a href={@actor.uri} target="_blank" rel="noopener noreferrer" class="flex-shrink-0">
            <%= if @actor.avatar_url do %>
              <img
                src={@actor.avatar_url}
                class="w-10 h-10 rounded-full object-cover"
                alt={@actor.username}
              />
            <% else %>
              <div class="w-10 h-10 rounded-full bg-base-300 flex items-center justify-center">
                <.icon
                  name={if @actor.actor_type == "Group", do: "hero-users", else: "hero-user"}
                  class="w-4 h-4"
                />
              </div>
            <% end %>
          </a>
          <div class="flex-1 min-w-0">
            <a
              href={@actor.uri}
              target="_blank"
              rel="noopener noreferrer"
              class="font-medium text-sm hover:underline block truncate"
            >
              {raw(
                render_display_name_with_emojis(
                  @actor.display_name || @actor.username,
                  @actor.domain
                )
              )}
            </a>
            <div class="text-xs opacity-70 truncate">
              {if @actor.actor_type == "Group", do: "!", else: "@"}{@actor.username}@{@actor.domain}
            </div>
            <%= if @actor.summary do %>
              <p class="text-xs mt-1 line-clamp-2 opacity-80">
                {HtmlSanitizeEx.strip_tags(@actor.summary) |> String.slice(0, 100)}
              </p>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Compact inline version for tight spaces like headers or toolbars.
  """
  attr :loading, :boolean, default: false
  attr :on_submit, :string, default: "follow_remote_user"
  attr :on_preview, :string, default: "preview_remote_user"
  attr :input_name, :string, default: "remote_handle"
  attr :placeholder, :string, default: "user@domain"
  attr :debounce, :integer, default: 500

  def fediverse_follow_inline(assigns) do
    ~H"""
    <form phx-submit={@on_submit} phx-change={@on_preview} class="flex items-center gap-2">
      <div class="relative">
        <input
          type="text"
          name={@input_name}
          placeholder={@placeholder}
          class="input input-xs input-bordered w-48 pr-8"
          phx-debounce={@debounce}
          required
        />
        <%= if @loading do %>
          <.spinner size="sm" class="absolute right-2 top-1/2 -translate-y-1/2" />
        <% end %>
      </div>
      <button type="submit" class="btn btn-secondary btn-xs" disabled={@loading}>
        <.icon name="hero-user-plus" class="w-3 h-3" />
      </button>
    </form>
    """
  end
end
