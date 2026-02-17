defmodule ElektrineWeb.Components.Social.ReplyItem do
  @moduledoc """
  Unified reply component that handles all reply formats:
  - Local replies (Message with sender)
  - Federated replies (Message with remote_actor)
  - Lemmy API comments (plain maps with author/author_domain)

  This ensures consistent styling and behavior across all reply types.
  """
  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]
  import ElektrineWeb.CoreComponents
  import ElektrineWeb.HtmlHelpers
  import ElektrineWeb.Components.User.Avatar
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.Components.User.HoverCard

  @doc """
  Renders a reply item with consistent styling regardless of source.

  ## Attributes

  * `:reply` - The reply (Message struct or Lemmy API map)
  * `:post` - The parent post (for context)
  * `:current_user` - Current logged-in user
  * `:user_statuses` - User presence statuses
  * `:user_follows` - Follow status map
  * `:pending_follows` - Pending follow requests
  * `:user_likes` - Like status map
  * `:timezone` - User timezone
  * `:time_format` - Time format preference
  * `:show_actions` - Whether to show action buttons
  * `:on_reply_click` - Event when clicking reply button
  """
  attr :reply, :map, required: true
  attr :post, :map, default: nil
  attr :current_user, :map, default: nil
  attr :user_statuses, :map, default: %{}
  attr :user_follows, :map, default: %{}
  attr :pending_follows, :map, default: %{}
  attr :user_likes, :map, default: %{}
  attr :timezone, :string, default: "UTC"
  attr :time_format, :string, default: "12h"
  attr :show_actions, :boolean, default: true
  attr :on_reply_click, :string, default: "show_reply_to_reply_form"

  def reply_item(assigns) do
    # Normalize the reply to a consistent format
    normalized = normalize_reply(assigns.reply)
    assigns = assign(assigns, :normalized, normalized)

    ~H"""
    <%= if @normalized.has_author do %>
      <div class="bg-base-50 rounded-lg p-3">
        <!-- Reply Header -->
        <div class="flex items-center gap-2 mb-2">
          <!-- Author Avatar -->
          <%= case @normalized.author_type do %>
            <% :local -> %>
              <.user_hover_card
                user={@reply.sender}
                user_statuses={@user_statuses}
                user_follows={@user_follows}
                current_user={@current_user}
              >
                <button
                  phx-click="navigate_to_profile"
                  phx-value-handle={@normalized.handle}
                  type="button"
                  class="w-8 h-8"
                >
                  <.user_avatar user={@reply.sender} size="xs" />
                </button>
              </.user_hover_card>
            <% :remote -> %>
              <.user_hover_card
                remote_actor={@reply.remote_actor}
                user_follows={@user_follows}
                pending_follows={@pending_follows}
                current_user={@current_user}
              >
                <.link
                  navigate={"/remote/#{@normalized.handle}@#{@normalized.domain}"}
                  class="w-8 h-8 block"
                  phx-click="stop_propagation"
                >
                  <%= if @normalized.avatar_url do %>
                    <img
                      src={@normalized.avatar_url}
                      alt={@normalized.handle}
                      class="w-8 h-8 rounded-full"
                    />
                  <% else %>
                    <.placeholder_avatar size="sm" />
                  <% end %>
                </.link>
              </.user_hover_card>
            <% :lemmy -> %>
              <.link
                navigate={"/remote/#{@normalized.handle}@#{@normalized.domain}"}
                class="w-8 h-8 block"
                phx-click="stop_propagation"
              >
                <%= if @normalized.avatar_url do %>
                  <img
                    src={@normalized.avatar_url}
                    alt={@normalized.handle}
                    class="w-8 h-8 rounded-full object-cover"
                  />
                <% else %>
                  <.placeholder_avatar size="sm" />
                <% end %>
              </.link>
          <% end %>
          
    <!-- Author Info -->
          <div class="flex-1 min-w-0 flex flex-col justify-center">
            <%= case @normalized.author_type do %>
              <% :local -> %>
                <.user_hover_card
                  user={@reply.sender}
                  user_statuses={@user_statuses}
                  user_follows={@user_follows}
                  current_user={@current_user}
                >
                  <button
                    phx-click="navigate_to_profile"
                    phx-value-handle={@normalized.handle}
                    type="button"
                    class="font-medium text-sm text-left truncate"
                  >
                    <.username_with_effects
                      user={@reply.sender}
                      display_name={true}
                      verified_size="xs"
                    />
                  </button>
                </.user_hover_card>
                <div class="text-xs opacity-70 truncate">
                  @{@normalized.handle}@z.org
                  <%= if @normalized.timestamp do %>
                    · {format_timestamp(@normalized.timestamp)}
                  <% end %>
                </div>
              <% :remote -> %>
                <.user_hover_card
                  remote_actor={@reply.remote_actor}
                  user_follows={@user_follows}
                  pending_follows={@pending_follows}
                  current_user={@current_user}
                >
                  <.link
                    navigate={"/remote/#{@normalized.handle}@#{@normalized.domain}"}
                    class="font-medium text-sm truncate block"
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
                <div class="text-xs opacity-70 truncate">
                  @{@normalized.handle}@{@normalized.domain}
                  <%= if @normalized.timestamp do %>
                    · {format_timestamp(@normalized.timestamp)}
                  <% end %>
                </div>
              <% :lemmy -> %>
                <.link
                  navigate={"/remote/#{@normalized.handle}@#{@normalized.domain}"}
                  class="font-medium text-sm truncate block"
                  phx-click="stop_propagation"
                >
                  {@normalized.display_name}
                </.link>
                <div class="text-xs opacity-70 truncate">
                  @{@normalized.handle}@{@normalized.domain}
                  <%= if @normalized.score do %>
                    · {@normalized.score} points
                  <% end %>
                </div>
            <% end %>
          </div>
        </div>
        
    <!-- Reply Content -->
        <%= if @normalized.content && String.trim(@normalized.content) != "" do %>
          <div class="text-sm break-words mb-2 [&_img]:max-w-[200px] [&_img]:max-h-[150px] [&_img]:rounded [&_img]:object-cover">
            {raw(
              @normalized.content
              |> String.trim()
              |> make_content_safe_with_links()
              |> render_custom_emojis()
              |> preserve_line_breaks()
            )}
          </div>
        <% end %>
        
    <!-- Reply Actions -->
        <%= if @show_actions && @current_user do %>
          <.reply_actions
            reply={@reply}
            normalized={@normalized}
            post={@post}
            current_user={@current_user}
            user_likes={@user_likes}
            on_reply_click={@on_reply_click}
          />
        <% end %>
      </div>
    <% end %>
    """
  end

  # Reply actions component
  attr :reply, :map, required: true
  attr :normalized, :map, required: true
  attr :post, :map, default: nil
  attr :current_user, :map, required: true
  attr :user_likes, :map, default: %{}
  attr :on_reply_click, :string, default: "show_reply_to_reply_form"

  defp reply_actions(assigns) do
    interaction_id = interactive_reply_id(assigns.reply)

    assigns =
      assigns
      |> assign(:interaction_id, interaction_id)
      |> assign(:reply_target_id, interaction_id || assigns.normalized.ap_id)

    ~H"""
    <div class="flex flex-wrap items-center gap-2">
      <%= if @interaction_id do %>
        <!-- Like Button -->
        <button
          phx-click="like_post"
          phx-value-message_id={@interaction_id}
          class={[
            "btn btn-xs btn-ghost",
            Map.get(@user_likes, @interaction_id, false) && "text-red-500"
          ]}
          type="button"
        >
          <% is_liked = Map.get(@user_likes, @interaction_id, false) %>
          <.icon
            name={
              if is_liked,
                do: "hero-heart-solid",
                else: "hero-heart"
            }
            class={["w-3 h-3", is_liked && "text-red-500"]}
          />
          <span class="text-xs">{@normalized.like_count}</span>
        </button>
      <% end %>
      
    <!-- Reply to Reply -->
      <%= if @post && @reply_target_id do %>
        <button
          phx-click={@on_reply_click}
          phx-value-reply_id={@reply_target_id}
          phx-value-post_id={@post.id}
          class="btn btn-xs btn-ghost"
          type="button"
          title="Reply to this comment"
        >
          <.icon name="hero-chat-bubble-left" class="w-3 h-3" />
          <%= if @normalized.reply_count > 0 do %>
            <span class="text-xs">{@normalized.reply_count}</span>
          <% end %>
        </button>
      <% end %>
      
    <!-- Boost Button -->
      <%= if @interaction_id do %>
        <button
          phx-click="boost_post"
          phx-value-message_id={@interaction_id}
          class="btn btn-xs btn-ghost"
          type="button"
        >
          <.icon name="hero-arrow-path" class="w-3 h-3" />
          <%= if @normalized.share_count > 0 do %>
            <span class="text-xs">{@normalized.share_count}</span>
          <% end %>
        </button>
      <% end %>

      <%= if !@interaction_id do %>
        <!-- Remote reply stats (read-only) -->
        <%= if @normalized.like_count > 0 || @normalized.score do %>
          <div class="flex items-center gap-1 text-xs opacity-60">
            <.icon name="hero-heart" class="w-3 h-3" />
            <span>{@normalized.score || @normalized.like_count}</span>
          </div>
        <% end %>
        <%= if @normalized.reply_count > 0 do %>
          <div class="flex items-center gap-1 text-xs opacity-60">
            <.icon name="hero-chat-bubble-left" class="w-3 h-3" />
            <span>{@normalized.reply_count}</span>
          </div>
        <% end %>
        <%= if @normalized.share_count > 0 do %>
          <div class="flex items-center gap-1 text-xs opacity-60">
            <.icon name="hero-arrow-path" class="w-3 h-3" />
            <span>{@normalized.share_count}</span>
          </div>
        <% end %>
        <!-- Link to original -->
        <%= if @normalized.ap_id do %>
          <a
            href={@normalized.ap_id}
            target="_blank"
            rel="noopener noreferrer"
            class="flex items-center gap-1 text-xs opacity-60 hover:opacity-100 hover:text-error transition-colors"
            title="Open on remote instance"
          >
            <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
          </a>
        <% end %>
      <% end %>
    </div>
    """
  end

  @doc """
  Normalizes a reply from any format to a consistent structure.
  """
  def normalize_reply(reply) do
    cond do
      # Local reply (Message with sender)
      Map.has_key?(reply, :sender) && reply.sender != nil ->
        %{
          author_type: :local,
          has_author: true,
          is_local: true,
          handle: reply.sender.handle || reply.sender.username,
          domain: nil,
          display_name: reply.sender.display_name || reply.sender.username,
          avatar_url: nil,
          content: reply.content,
          timestamp: reply.inserted_at,
          like_count: reply.like_count || 0,
          reply_count: reply.reply_count || 0,
          share_count: reply.share_count || 0,
          score: nil,
          ap_id: reply.activitypub_id
        }

      # Federated reply (Message with remote_actor)
      Map.has_key?(reply, :remote_actor) && reply.remote_actor != nil &&
          !is_struct(reply.remote_actor, Ecto.Association.NotLoaded) ->
        %{
          author_type: :remote,
          has_author: true,
          is_local: false,
          handle: reply.remote_actor.username,
          domain: reply.remote_actor.domain,
          display_name: reply.remote_actor.display_name || reply.remote_actor.username,
          avatar_url: reply.remote_actor.avatar_url,
          content: reply.content,
          timestamp: reply.inserted_at,
          like_count: reply.like_count || 0,
          reply_count: reply.reply_count || 0,
          share_count: reply.share_count || 0,
          score: nil,
          ap_id: reply.activitypub_id || reply.activitypub_url
        }

      # Lemmy API comment (plain map with author/author_domain)
      Map.has_key?(reply, :author) && reply.author != nil ->
        %{
          author_type: :lemmy,
          has_author: true,
          is_local: false,
          handle: reply.author,
          domain: reply.author_domain,
          display_name: reply.author,
          avatar_url: reply[:author_avatar] || reply[:avatar_url],
          content: reply.content,
          timestamp: nil,
          like_count: 0,
          reply_count: reply[:child_count] || 0,
          share_count: 0,
          score: reply[:score] || reply[:upvotes],
          ap_id: reply[:ap_id]
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
          content: Map.get(reply, :content),
          timestamp: nil,
          like_count: 0,
          reply_count: 0,
          share_count: 0,
          score: nil,
          ap_id: nil
        }
    end
  end

  defp format_timestamp(nil), do: nil

  defp format_timestamp(datetime) do
    Elektrine.Social.time_ago_in_words(datetime)
  end

  # Federated replies can be interactive when we've materialized them as local messages.
  defp interactive_reply_id(reply) when is_map(reply) do
    case Map.get(reply, :id) do
      id when is_integer(id) ->
        id

      id when is_binary(id) ->
        case Integer.parse(id) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp interactive_reply_id(_), do: nil
end
