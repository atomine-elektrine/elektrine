defmodule ElektrineWeb.Components.Social.PostReactions do
  @moduledoc """
  Reusable emoji reactions component for posts.
  Provides consistent styling and behavior across all post types.
  """
  use Phoenix.Component
  import ElektrineWeb.CoreComponents

  @default_emojis ["👍", "❤️", "😂", "🔥", "😮", "😢"]

  @doc """
  Renders emoji reactions with a quick picker dropdown.

  ## Attributes

  * `:post_id` - The post identifier (can be integer ID or ActivityPub URI string)
  * `:reactions` - List of reaction records (with emoji, user, remote_actor fields)
  * `:current_user` - The current user (nil if not logged in)
  * `:on_react` - Event name for react action (default: "react_to_post")
  * `:size` - Button size: :xs, :sm (default: :xs)
  * `:value_name` - The phx-value attribute name: "post_id" or "message_id" (default: "post_id")
  * `:show_picker` - Whether to show the quick picker (default: true)
  * `:emojis` - List of emojis for quick picker (default: standard set)

  ## Examples

      <.post_reactions
        post_id={post.id}
        reactions={@post_reactions[post.id] || []}
        current_user={@current_user}
      />

      <!-- With custom size -->
      <.post_reactions
        post_id={post.id}
        reactions={reactions}
        current_user={@current_user}
        size={:sm}
      />
  """
  attr :post_id, :any, required: true
  attr :reactions, :list, default: []
  attr :current_user, :map, default: nil
  attr :on_react, :string, default: "react_to_post"
  attr :size, :atom, default: :xs
  attr :value_name, :string, default: "post_id"
  attr :show_picker, :boolean, default: true
  attr :emojis, :list, default: @default_emojis

  def post_reactions(assigns) do
    current_user_id = if assigns.current_user, do: assigns.current_user.id, else: nil

    # Group reactions by emoji and count
    grouped_reactions = Enum.group_by(assigns.reactions, & &1.emoji)

    formatted_reactions =
      Enum.map(grouped_reactions, fn {emoji, reactions} ->
        user_reacted = Enum.any?(reactions, fn r -> r.user_id == current_user_id end)

        # Get usernames for tooltip
        usernames =
          reactions
          |> Enum.map(fn r ->
            cond do
              r.user && r.user.username ->
                r.user.username

              r.remote_actor && r.remote_actor.username ->
                "#{r.remote_actor.username}@#{r.remote_actor.domain}"

              true ->
                nil
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.take(10)

        %{
          emoji: emoji,
          count: length(reactions),
          user_reacted: user_reacted,
          usernames: usernames
        }
      end)
      |> Enum.sort_by(& &1.count, :desc)

    # Size-based classes
    {btn_class, text_class, icon_class, picker_btn_class, picker_icon_class} =
      case assigns.size do
        :xs ->
          {
            "btn btn-xs sm:btn-sm gap-1 min-w-0",
            "text-xs sm:text-sm",
            "w-3.5 h-3.5 sm:w-4 sm:h-4",
            "btn btn-ghost btn-xs sm:btn-sm",
            "w-3.5 h-3.5 sm:w-4 sm:h-4"
          }

        :sm ->
          {
            "btn btn-sm gap-1 min-w-0",
            "text-sm",
            "w-4 h-4",
            "btn btn-ghost btn-sm",
            "w-4 h-4"
          }

        _ ->
          {
            "btn btn-xs sm:btn-sm gap-1 min-w-0",
            "text-xs sm:text-sm",
            "w-3.5 h-3.5 sm:w-4 sm:h-4",
            "btn btn-ghost btn-xs sm:btn-sm",
            "w-3.5 h-3.5 sm:w-4 sm:h-4"
          }
      end

    assigns =
      assigns
      |> assign(:formatted_reactions, formatted_reactions)
      |> assign(:btn_class, btn_class)
      |> assign(:text_class, text_class)
      |> assign(:icon_class, icon_class)
      |> assign(:picker_btn_class, picker_btn_class)
      |> assign(:picker_icon_class, picker_icon_class)

    ~H"""
    <%= if length(@formatted_reactions) > 0 || (@current_user && @show_picker) do %>
      <div class="flex flex-wrap items-center gap-1.5">
        <!-- Existing reactions -->
        <%= for reaction <- @formatted_reactions do %>
          <% tooltip = Enum.join(reaction.usernames, ", ")

          tooltip =
            if reaction.count > 10, do: tooltip <> " and #{reaction.count - 10} more", else: tooltip %>
          <button
            phx-click={@on_react}
            {[{"phx-value-#{@value_name}", @post_id}]}
            phx-value-emoji={reaction.emoji}
            class={[
              @btn_class,
              "tooltip tooltip-top",
              if(reaction.user_reacted, do: "btn-secondary", else: "btn-ghost")
            ]}
            type="button"
            data-tip={tooltip}
          >
            <span>{reaction.emoji}</span>
            <span class={@text_class}>{reaction.count}</span>
          </button>
        <% end %>
        
    <!-- Quick reaction picker -->
        <%= if @current_user && @show_picker do %>
          <div class="dropdown dropdown-top">
            <label tabindex="0" class={@picker_btn_class} title="Add reaction">
              <.icon name="hero-face-smile" class={@picker_icon_class} />
            </label>
            <div
              tabindex="0"
              class="dropdown-content z-30 menu p-2 shadow-lg bg-base-100 rounded-box border border-base-300"
            >
              <div class="flex gap-1">
                <%= for emoji <- @emojis do %>
                  <button
                    phx-click={@on_react}
                    {[{"phx-value-#{@value_name}", @post_id}]}
                    phx-value-emoji={emoji}
                    class="btn btn-ghost btn-sm text-lg"
                    type="button"
                  >
                    {emoji}
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end
end
