defmodule ElektrineWeb.Components.Social.PostHeader do
  @moduledoc """
  Unified post header component that handles all post author formats:
  - Local posts (Message with sender)
  - Federated posts (Message with remote_actor)

  This ensures consistent styling and behavior across all post types.
  """
  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]
  import ElektrineWeb.CoreComponents
  import ElektrineWeb.HtmlHelpers
  import ElektrineWeb.Components.User.Avatar
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.Components.User.HoverCard
  alias ElektrineWeb.Components.Social.PostUtilities

  @doc """
  Renders a post header with consistent styling regardless of source.

  ## Attributes

  * `:post` - The post (Message struct)
  * `:current_user` - Current logged-in user
  * `:user_statuses` - User presence statuses
  * `:user_follows` - Follow status map
  * `:pending_follows` - Pending follow requests
  * `:timezone` - User timezone
  * `:time_format` - Time format preference
  """
  attr :post, :map, required: true
  attr :current_user, :map, default: nil
  attr :user_statuses, :map, default: %{}
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "12h"

  def post_header(assigns) do
    normalized = normalize_post(assigns.post)
    assigns = assign(assigns, :normalized, normalized)

    ~H"""
    <%= if @normalized.has_author do %>
      <div class="flex items-center gap-3">
        <!-- Author Avatar -->
        <%= case @normalized.author_type do %>
          <% :local -> %>
            <.user_hover_card
              user={@post.sender}
              user_statuses={@user_statuses}
              user_follows={@user_follows}
              current_user={@current_user}
            >
              <button
                phx-click="navigate_to_profile"
                phx-value-handle={@normalized.handle}
                type="button"
                class="w-10 h-10"
              >
                <.user_avatar
                  user={@post.sender}
                  size="sm"
                  user_statuses={@user_statuses}
                />
              </button>
            </.user_hover_card>
          <% :remote -> %>
            <.user_hover_card
              remote_actor={@post.remote_actor}
              user_follows={@user_follows}
              pending_follows={@pending_follows}
              current_user={@current_user}
            >
              <.link
                navigate={"/remote/#{@normalized.handle}@#{@normalized.domain}"}
                class="w-10 h-10 rounded-full block"
                phx-click="stop_propagation"
              >
                <%= if @normalized.avatar_url do %>
                  <img
                    src={@normalized.avatar_url}
                    alt={@normalized.handle}
                    class="w-10 h-10 rounded-full object-cover shadow-lg"
                  />
                <% else %>
                  <.placeholder_avatar size="md" class="shadow-lg" />
                <% end %>
              </.link>
            </.user_hover_card>
        <% end %>
        
    <!-- Author Info -->
        <div class="flex-1 min-w-0 flex flex-col justify-center">
          <%= case @normalized.author_type do %>
            <% :local -> %>
              <.user_hover_card
                user={@post.sender}
                user_statuses={@user_statuses}
                user_follows={@user_follows}
                current_user={@current_user}
              >
                <button
                  phx-click="navigate_to_profile"
                  phx-value-handle={@normalized.handle}
                  class="font-medium hover:text-error transition-colors text-left"
                  type="button"
                >
                  <.username_with_effects
                    user={@post.sender}
                    display_name={true}
                    verified_size="sm"
                  />
                </button>
              </.user_hover_card>
              <div class="text-sm opacity-70 flex items-center gap-2 truncate">
                <span class="truncate">
                  @{@normalized.handle}@z.org ·
                  <.local_time
                    datetime={@normalized.timestamp}
                    format="relative"
                    timezone={@timezone}
                    time_format={@time_format}
                  />
                </span>
                <%= if @normalized.edited_at do %>
                  <span
                    class="badge badge-xs badge-ghost flex-shrink-0"
                    title={"Edited #{Elektrine.Social.time_ago_in_words(@normalized.edited_at)}"}
                  >
                    <.icon name="hero-pencil" class="w-2.5 h-2.5" />
                  </span>
                <% end %>
                <.visibility_badge visibility={@normalized.visibility} />
              </div>
            <% :remote -> %>
              <div class="flex items-center gap-1.5">
                <.user_hover_card
                  remote_actor={@post.remote_actor}
                  user_follows={@user_follows}
                  pending_follows={@pending_follows}
                  current_user={@current_user}
                >
                  <.link
                    navigate={"/remote/#{@normalized.handle}@#{@normalized.domain}"}
                    class="font-medium hover:text-purple-600 transition-colors duration-200 truncate"
                    phx-click="stop_propagation"
                  >
                    {raw(
                      render_display_name_with_emojis(
                        @normalized.display_name,
                        @normalized.domain
                      )
                    )}
                  </.link>
                </.user_hover_card>
                <%= if @normalized.community_uri do %>
                  <span class="badge badge-xs badge-purple flex-shrink-0">
                    <.icon name="hero-users" class="w-2.5 h-2.5 mr-0.5" /> Community
                  </span>
                <% end %>
              </div>
              <div class="text-sm opacity-70 flex items-center gap-2 truncate">
                <span class="truncate">
                  @{@normalized.handle}@{@normalized.domain}
                  <%= if @normalized.community_uri do %>
                    <span class="opacity-50">in</span>
                    <a
                      href={@normalized.community_uri}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="link link-hover"
                    >
                      {extract_community_name(@normalized.community_uri)}
                    </a>
                  <% end %>
                  ·
                  <.local_time
                    datetime={@normalized.timestamp}
                    format="relative"
                    timezone={@timezone}
                    time_format={@time_format}
                  />
                </span>
                <%= if @normalized.edited_at do %>
                  <span
                    class="badge badge-xs badge-ghost"
                    title={"Edited #{Elektrine.Social.time_ago_in_words(@normalized.edited_at)}"}
                  >
                    <.icon name="hero-pencil" class="w-2.5 h-2.5" />
                  </span>
                <% end %>
              </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  # Visibility badge component
  attr :visibility, :string, default: nil

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

  @doc """
  Normalizes a post from any format to a consistent structure.
  """
  def normalize_post(post) do
    cond do
      # Local post (Message with sender)
      Map.has_key?(post, :sender) && sender_loaded?(post.sender) ->
        %{
          author_type: :local,
          has_author: true,
          is_local: true,
          handle: post.sender.handle || post.sender.username,
          domain: nil,
          display_name: post.sender.display_name || post.sender.username,
          avatar_url: nil,
          timestamp: post.inserted_at,
          edited_at: post.edited_at,
          visibility: post.visibility,
          community_uri: nil,
          ap_id: post.activitypub_id
        }

      # Federated post (Message with remote_actor)
      Map.has_key?(post, :remote_actor) && assoc_loaded?(post.remote_actor) ->
        %{
          author_type: :remote,
          has_author: true,
          is_local: false,
          handle: post.remote_actor.username,
          domain: post.remote_actor.domain,
          display_name: post.remote_actor.display_name || post.remote_actor.username,
          avatar_url: post.remote_actor.avatar_url,
          timestamp: post.inserted_at,
          edited_at: post.edited_at,
          visibility: nil,
          community_uri: PostUtilities.community_actor_uri(post),
          ap_id: post.activitypub_id || post.activitypub_url
        }

      # Unknown format - no author
      true ->
        %{
          author_type: :unknown,
          has_author: false,
          is_local: false,
          handle: nil,
          domain: nil,
          display_name: nil,
          avatar_url: nil,
          timestamp: nil,
          edited_at: nil,
          visibility: nil,
          community_uri: nil,
          ap_id: nil
        }
    end
  end

  defp extract_community_name(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{path: path} when is_binary(path) ->
        path
        |> String.split("/")
        |> List.last()
        |> then(fn name -> if name == "", do: uri, else: name end)

      _ ->
        uri
    end
  end

  defp extract_community_name(_), do: "Community"

  # Check if sender association is loaded and has required fields
  defp sender_loaded?(nil), do: false
  defp sender_loaded?(%Ecto.Association.NotLoaded{}), do: false

  defp sender_loaded?(sender) do
    is_map(sender) && Map.has_key?(sender, :username)
  end

  # Check if any association is loaded (not nil and not NotLoaded)
  defp assoc_loaded?(nil), do: false
  defp assoc_loaded?(%Ecto.Association.NotLoaded{}), do: false
  defp assoc_loaded?(_), do: true
end
