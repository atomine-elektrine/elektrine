defmodule ElektrineSocialWeb.Components.Social.PostActions do
  @moduledoc """
  Reusable post interaction buttons: like, comment, boost.
  Provides consistent styling and behavior across all post types.
  """
  use Phoenix.Component
  import ElektrineWeb.CoreComponents

  @doc """
  Renders a horizontal row of post action buttons with DaisyUI btn styling.

  ## Attributes

  * `:post_id` - The post identifier (can be integer ID or ActivityPub URI string)
  * `:current_user` - The current user (nil if not logged in)
  * `:is_liked` - Whether the current user has liked this post
  * `:is_boosted` - Whether the current user has boosted this post
  * `:like_count` - Number of likes
  * `:comment_count` - Number of comments/replies
  * `:boost_count` - Number of boosts/shares
  * `:on_like` - Event name for like action (default: "like_post")
  * `:on_unlike` - Event name for unlike action (default: "unlike_post")
  * `:on_comment` - Event name for comment action (default: "show_reply_form")
  * `:on_boost` - Event name for boost action (default: "boost_post")
  * `:on_unboost` - Event name for unboost action (default: "unboost_post")
  * `:show_comment` - Whether to show comment button (default: true)
  * `:show_boost` - Whether to show boost button (default: true)
  * `:show_like` - Whether to show like button (default: true)
  * `:value_name` - The phx-value attribute name: "post_id" or "message_id" (default: "post_id")
  * `:size` - Button size: :xs, :sm, :md (default: :sm)
  * `:style` - Style variant: :default, :minimal (default: :default)

  ## Examples

      <.post_actions
        post_id={post.id}
        current_user={@current_user}
        is_liked={@user_likes[post.id]}
        is_boosted={@user_boosts[post.id]}
        like_count={post.like_count}
        comment_count={post.reply_count}
        boost_count={post.share_count}
      />

      <!-- Timeline style with message_id -->
      <.post_actions
        post_id={post.id}
        value_name="message_id"
        current_user={@current_user}
        is_liked={@user_likes[post.id]}
        is_boosted={@user_boosts[post.id]}
        like_count={post.like_count}
        comment_count={post.reply_count}
        boost_count={post.share_count}
      />
  """
  attr :post_id, :any, required: true
  attr :current_user, :map, default: nil
  attr :is_liked, :boolean, default: false
  attr :is_boosted, :boolean, default: false
  attr :like_count, :integer, default: 0
  attr :comment_count, :integer, default: 0
  attr :boost_count, :integer, default: 0
  attr :on_like, :string, default: "like_post"
  attr :on_unlike, :string, default: "unlike_post"
  attr :on_comment, :string, default: "show_reply_form"
  attr :on_boost, :string, default: "boost_post"
  attr :on_unboost, :string, default: "unboost_post"
  attr :on_quote, :string, default: "quote_post"
  attr :on_save, :string, default: "save_post"
  attr :on_unsave, :string, default: "unsave_post"
  attr :on_react, :string, default: "react_to_post"
  attr :show_comment, :boolean, default: true
  attr :show_boost, :boolean, default: true
  attr :show_quote, :boolean, default: true
  attr :show_like, :boolean, default: true
  attr :show_react, :boolean, default: false
  attr :show_save, :boolean, default: true
  attr :is_saved, :boolean, default: false
  attr :quote_count, :integer, default: 0
  attr :reactions, :list, default: []
  attr :react_post_id, :any, default: nil
  attr :react_value_name, :string, default: nil
  attr :react_emoji, :string, default: "👍"
  attr :emojis, :list, default: ["👍", "❤️", "😂", "🔥", "😮", "😢"]
  attr :actor_uri, :string, default: nil
  attr :value_name, :string, default: "post_id"
  attr :save_post_id, :any, default: nil
  attr :save_value_name, :string, default: nil
  attr :comment_value_name, :string, default: nil
  attr :comment_path, :string, default: nil
  attr :size, :atom, default: :sm
  attr :style, :atom, default: :default
  attr :dom_id_prefix, :string, default: nil
  attr :counts_loading, :boolean, default: false
  attr :container_class, :any, default: nil

  def post_actions(assigns) do
    {icon_size, btn_class, text_class} =
      case assigns.size do
        :xs ->
          {"w-3.5 h-3.5 sm:w-4 sm:h-4 flex-shrink-0",
           "btn btn-ghost btn-sm sm:btn-xs px-2 h-9 min-h-9 gap-1 sm:px-2 sm:h-8 sm:min-h-8 sm:gap-1",
           "text-[10px] sm:text-xs tabular-nums"}

        :sm ->
          {"w-3.5 h-3.5 sm:w-4 sm:h-4 flex-shrink-0",
           "btn btn-ghost btn-sm px-2.5 h-10 min-h-10 gap-1 sm:btn-sm sm:px-2 sm:h-8 sm:min-h-8 sm:gap-1",
           "text-[10px] sm:text-sm tabular-nums"}

        :md ->
          {"w-4 h-4 sm:w-5 sm:h-5 flex-shrink-0", "btn btn-ghost btn-sm px-2 sm:btn-md sm:px-3",
           "text-xs sm:text-base tabular-nums"}

        _ ->
          {"w-3.5 h-3.5 sm:w-4 sm:h-4 flex-shrink-0",
           "btn btn-ghost btn-sm px-2.5 h-10 min-h-10 gap-1 sm:btn-sm sm:px-2 sm:h-8 sm:min-h-8 sm:gap-1",
           "text-[10px] sm:text-sm tabular-nums"}
      end

    # Use per-action value overrides when set, otherwise fall back to value_name.
    actual_comment_value_name = assigns.comment_value_name || assigns.value_name
    actual_save_value_name = assigns.save_value_name || assigns.value_name
    actual_save_post_id = assigns.save_post_id || assigns.post_id
    actual_react_value_name = assigns.react_value_name || assigns.value_name
    actual_react_post_id = assigns.react_post_id || assigns.post_id

    assigns =
      assigns
      |> assign(:icon_size, icon_size)
      |> assign(:btn_class, btn_class)
      |> assign(:text_class, text_class)
      |> assign(:actual_comment_value_name, actual_comment_value_name)
      |> assign(:actual_save_value_name, actual_save_value_name)
      |> assign(:actual_save_post_id, actual_save_post_id)
      |> assign(:actual_react_value_name, actual_react_value_name)
      |> assign(:actual_react_post_id, actual_react_post_id)
      |> assign(:dom_id_prefix, assigns.dom_id_prefix || default_dom_id_prefix(assigns))

    if assigns.style == :minimal do
      render_minimal(assigns)
    else
      render_default(assigns)
    end
  end

  defp render_default(assigns) do
    ~H"""
    <div class={["flex items-center gap-1.5 post-actions-container", @container_class]}>
      <%= if @show_like do %>
        <%= if @current_user do %>
          <button
            phx-click={if @is_liked, do: @on_unlike, else: @on_like}
            {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
            id={action_button_id(@dom_id_prefix, "like")}
            data-action-lock-key={action_lock_key(@dom_id_prefix, "like")}
            class={[
              @btn_class,
              "cursor-pointer transition-colors phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
              @is_liked &&
                "bg-primary/10 text-primary phx-click-loading:bg-transparent phx-click-loading:text-base-content/70",
              !@is_liked &&
                "hover:text-primary phx-click-loading:bg-primary/10 phx-click-loading:text-primary"
            ]}
            type="button"
          >
            <span class="inline-flex items-center gap-1">
              <.icon
                name={if @is_liked, do: "hero-heart-solid", else: "hero-heart"}
                class={[@icon_size, @is_liked && "text-primary"]}
              />
              <.animated_count
                id={count_id(@dom_id_prefix, "like")}
                class={@text_class}
                count={@like_count}
                loading={@counts_loading}
              />
            </span>
          </button>
        <% else %>
          <div class={[@btn_class, "cursor-default opacity-60"]}>
            <.icon name="hero-heart" class={@icon_size} />
            <.animated_count
              id={count_id(@dom_id_prefix, "like")}
              class={@text_class}
              count={@like_count}
              loading={@counts_loading}
            />
          </div>
        <% end %>
      <% end %>

      <%= if @show_comment do %>
        <%= if @comment_path do %>
          <.link
            navigate={@comment_path}
            class={[
              @btn_class,
              "cursor-pointer transition-colors hover:text-primary"
            ]}
          >
            <.icon name="hero-chat-bubble-left" class={@icon_size} />
            <.animated_count
              id={count_id(@dom_id_prefix, "comment")}
              class={@text_class}
              count={@comment_count}
              loading={@counts_loading}
            />
          </.link>
        <% else %>
          <%= if @current_user do %>
            <button
              phx-click={@on_comment}
              {[{"phx-value-#{@actual_comment_value_name}", @post_id}]}
              data-action-lock-key={action_lock_key(@dom_id_prefix, "comment")}
              class={[
                @btn_class,
                "cursor-pointer transition-colors hover:text-primary phx-click-loading:pointer-events-none phx-click-loading:cursor-wait"
              ]}
              type="button"
            >
              <.icon name="hero-chat-bubble-left" class={@icon_size} />
              <.animated_count
                id={count_id(@dom_id_prefix, "comment")}
                class={@text_class}
                count={@comment_count}
                loading={@counts_loading}
              />
            </button>
          <% else %>
            <div class={[@btn_class, "cursor-default opacity-60"]}>
              <.icon name="hero-chat-bubble-left" class={@icon_size} />
              <.animated_count
                id={count_id(@dom_id_prefix, "comment")}
                class={@text_class}
                count={@comment_count}
                loading={@counts_loading}
              />
            </div>
          <% end %>
        <% end %>
      <% end %>

      <%= if @show_boost do %>
        <%= if @current_user do %>
          <button
            phx-click={if @is_boosted, do: @on_unboost, else: @on_boost}
            {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
            id={action_button_id(@dom_id_prefix, "boost")}
            data-action-lock-key={action_lock_key(@dom_id_prefix, "boost")}
            class={[
              @btn_class,
              "cursor-pointer transition-colors phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
              @is_boosted &&
                "bg-accent/10 text-accent phx-click-loading:bg-transparent phx-click-loading:text-base-content/70",
              !@is_boosted &&
                "hover:text-accent phx-click-loading:bg-accent/10 phx-click-loading:text-accent"
            ]}
            type="button"
            title={if @is_boosted, do: "Unboost", else: "Boost"}
          >
            <span class="inline-flex items-center gap-1">
              <.icon
                name={if @is_boosted, do: "hero-arrow-path-solid", else: "hero-arrow-path"}
                class={[@icon_size, @is_boosted && "text-accent"]}
              />
              <.animated_count
                id={count_id(@dom_id_prefix, "boost")}
                class={@text_class}
                count={@boost_count}
                loading={@counts_loading}
              />
            </span>
          </button>
        <% else %>
          <div class={[@btn_class, "cursor-default opacity-60"]}>
            <.icon name="hero-arrow-path" class={@icon_size} />
            <.animated_count
              id={count_id(@dom_id_prefix, "boost")}
              class={@text_class}
              count={@boost_count}
              loading={@counts_loading}
            />
          </div>
        <% end %>
      <% end %>

      <%= if @show_quote do %>
        <%= if @current_user do %>
          <button
            phx-click={@on_quote}
            {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
            data-action-lock-key={action_lock_key(@dom_id_prefix, "quote")}
            class={[
              @btn_class,
              "cursor-pointer hidden sm:flex transition-colors hover:text-secondary phx-click-loading:pointer-events-none phx-click-loading:cursor-wait"
            ]}
            type="button"
            title="Quote post"
          >
            <.icon name="hero-chat-bubble-bottom-center-text" class={@icon_size} />
            <.animated_count
              id={count_id(@dom_id_prefix, "quote")}
              class={@text_class}
              count={@quote_count}
              loading={@counts_loading}
            />
          </button>
        <% else %>
          <div class={[@btn_class, "cursor-default opacity-60 hidden sm:flex"]}>
            <.icon name="hero-chat-bubble-bottom-center-text" class={@icon_size} />
            <.animated_count
              id={count_id(@dom_id_prefix, "quote")}
              class={@text_class}
              count={@quote_count}
              loading={@counts_loading}
            />
          </div>
        <% end %>
      <% end %>

      <%= if @show_react do %>
        <%= if @current_user do %>
          <details
            class="dropdown dropdown-end dropdown-top timeline-reaction-dropdown ml-0.5"
            data-reaction-picker-root
          >
            <summary
              class={[
                @btn_class,
                "w-9 justify-center px-0 sm:w-8 sm:px-0 cursor-pointer list-none transition-colors [&::-webkit-details-marker]:hidden",
                user_reacted_any?(@reactions, @current_user, @emojis) &&
                  "bg-primary/10 text-primary",
                !user_reacted_any?(@reactions, @current_user, @emojis) && "hover:text-primary"
              ]}
              title="React"
              aria-label="React"
            >
              <.icon name="hero-face-smile" class={@icon_size} />
            </summary>
            <div class="dropdown-content bottom-full right-0 z-[320] mb-2 menu rounded-box border border-base-300 bg-base-100 p-2 shadow-lg">
              <div class="flex gap-1.5">
                <%= for emoji <- @emojis do %>
                  <button
                    phx-click={@on_react}
                    {reaction_value_attrs(@actual_react_value_name, @actual_react_post_id, emoji, @actor_uri)}
                    class={[
                      "btn btn-ghost btn-sm text-lg",
                      user_reacted?(@reactions, @current_user, emoji) && "btn-primary"
                    ]}
                    type="button"
                  >
                    {emoji}
                  </button>
                <% end %>
              </div>
            </div>
          </details>
        <% else %>
          <div class={[@btn_class, "w-9 justify-center px-0 sm:w-8 sm:px-0 cursor-default opacity-60"]}>
            <.icon name="hero-face-smile" class={@icon_size} />
          </div>
        <% end %>
      <% end %>

      <%= if @show_save do %>
        <%= if @current_user do %>
          <button
            phx-click={if @is_saved, do: @on_unsave, else: @on_save}
            {[{"phx-value-#{@actual_save_value_name}", @actual_save_post_id}]}
            id={action_button_id(@dom_id_prefix, "save")}
            data-action-lock-key={action_lock_key(@dom_id_prefix, "save")}
            class={[
              @btn_class,
              "w-9 justify-center px-0 sm:w-8 sm:px-0",
              "cursor-pointer transition-colors phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
              @is_saved &&
                "bg-primary/10 text-primary phx-click-loading:bg-transparent phx-click-loading:text-base-content/70",
              !@is_saved &&
                "hover:text-primary phx-click-loading:bg-primary/10 phx-click-loading:text-primary"
            ]}
            type="button"
            title={if @is_saved, do: "Remove from saved", else: "Save"}
          >
            <span class="inline-flex items-center">
              <.icon
                name={if @is_saved, do: "hero-bookmark-solid", else: "hero-bookmark"}
                class={[@icon_size, @is_saved && "text-primary"]}
              />
            </span>
          </button>
        <% else %>
          <div class={[@btn_class, "w-9 justify-center px-0 sm:w-8 sm:px-0 cursor-default opacity-60"]}>
            <.icon name="hero-bookmark" class={@icon_size} />
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp render_minimal(assigns) do
    ~H"""
    <div class="flex items-center gap-4 text-sm">
      <%= if @show_like do %>
        <%= if @current_user do %>
          <button
            phx-click={if @is_liked, do: @on_unlike, else: @on_like}
            {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
            id={action_button_id(@dom_id_prefix, "like")}
            data-action-lock-key={action_lock_key(@dom_id_prefix, "like")}
            class={[
              "flex items-center gap-1.5 transition-all duration-150 cursor-pointer phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
              if(@is_liked,
                do: "text-primary phx-click-loading:text-base-content/60",
                else: "text-base-content/60 hover:text-primary phx-click-loading:text-primary"
              )
            ]}
            type="button"
          >
            <span class="inline-flex items-center gap-1.5">
              <.icon
                name={if @is_liked, do: "hero-heart-solid", else: "hero-heart"}
                class={[@icon_size, @is_liked && "text-primary"]}
              />
              <.animated_count
                id={count_id(@dom_id_prefix, "like")}
                count={@like_count}
                loading={@counts_loading}
              />
            </span>
          </button>
        <% else %>
          <div class="flex items-center gap-1.5 opacity-50 cursor-default">
            <.icon name="hero-heart" class={@icon_size} />
            <.animated_count
              id={count_id(@dom_id_prefix, "like")}
              count={@like_count}
              loading={@counts_loading}
            />
          </div>
        <% end %>
      <% end %>

      <%= if @show_comment do %>
        <%= if @comment_path do %>
          <.link
            navigate={@comment_path}
            class="flex items-center gap-1.5 text-base-content/60 hover:text-primary transition-colors cursor-pointer"
          >
            <.icon name="hero-chat-bubble-left" class={@icon_size} />
            <.animated_count
              id={count_id(@dom_id_prefix, "comment")}
              count={@comment_count}
              loading={@counts_loading}
            />
          </.link>
        <% end %>
        <%= if !@comment_path do %>
          <%= if @current_user do %>
            <button
              phx-click={@on_comment}
              {[{"phx-value-#{@actual_comment_value_name}", @post_id}]}
              data-action-lock-key={action_lock_key(@dom_id_prefix, "comment")}
              class="flex items-center gap-1.5 text-base-content/60 hover:text-primary transition-colors cursor-pointer phx-click-loading:pointer-events-none phx-click-loading:cursor-wait"
              type="button"
            >
              <.icon name="hero-chat-bubble-left" class={@icon_size} />
              <.animated_count
                id={count_id(@dom_id_prefix, "comment")}
                count={@comment_count}
                loading={@counts_loading}
              />
            </button>
          <% else %>
            <div class="flex items-center gap-1.5 opacity-50 cursor-default">
              <.icon name="hero-chat-bubble-left" class={@icon_size} />
              <.animated_count
                id={count_id(@dom_id_prefix, "comment")}
                count={@comment_count}
                loading={@counts_loading}
              />
            </div>
          <% end %>
        <% end %>
      <% end %>

      <%= if @show_boost do %>
        <%= if @current_user do %>
          <button
            phx-click={if @is_boosted, do: @on_unboost, else: @on_boost}
            {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
            id={action_button_id(@dom_id_prefix, "boost")}
            data-action-lock-key={action_lock_key(@dom_id_prefix, "boost")}
            class={[
              "flex items-center gap-1.5 transition-all duration-150 cursor-pointer phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
              if(@is_boosted,
                do: "text-accent phx-click-loading:text-base-content/60",
                else: "text-base-content/60 hover:text-accent phx-click-loading:text-accent"
              )
            ]}
            type="button"
          >
            <span class="inline-flex items-center gap-1.5">
              <.icon
                name={if @is_boosted, do: "hero-arrow-path-solid", else: "hero-arrow-path"}
                class={@icon_size}
              />
              <.animated_count
                id={count_id(@dom_id_prefix, "boost")}
                count={@boost_count}
                loading={@counts_loading}
              />
            </span>
          </button>
        <% else %>
          <div class="flex items-center gap-1.5 opacity-50 cursor-default">
            <.icon name="hero-arrow-path" class={@icon_size} />
            <.animated_count
              id={count_id(@dom_id_prefix, "boost")}
              count={@boost_count}
              loading={@counts_loading}
            />
          </div>
        <% end %>
      <% end %>

      <%= if @show_react do %>
        <%= if @current_user do %>
          <details
            class="dropdown dropdown-end dropdown-top timeline-reaction-dropdown"
            data-reaction-picker-root
          >
            <summary
              class={[
                "flex h-8 w-8 items-center justify-center rounded-md transition-all duration-150 cursor-pointer list-none [&::-webkit-details-marker]:hidden",
                if(user_reacted_any?(@reactions, @current_user, @emojis),
                  do: "text-primary",
                  else: "text-base-content/60 hover:text-primary"
                )
              ]}
              title="React"
              aria-label="React"
            >
              <.icon name="hero-face-smile" class={@icon_size} />
            </summary>
            <div class="dropdown-content bottom-full right-0 z-[320] mb-2 menu rounded-box border border-base-300 bg-base-100 p-2 shadow-lg">
              <div class="flex gap-1.5">
                <%= for emoji <- @emojis do %>
                  <button
                    phx-click={@on_react}
                    {reaction_value_attrs(@actual_react_value_name, @actual_react_post_id, emoji, @actor_uri)}
                    class={[
                      "btn btn-ghost btn-sm text-lg",
                      user_reacted?(@reactions, @current_user, emoji) && "btn-primary"
                    ]}
                    type="button"
                  >
                    {emoji}
                  </button>
                <% end %>
              </div>
            </div>
          </details>
        <% else %>
          <div class="flex h-8 w-8 items-center justify-center rounded-md opacity-50 cursor-default">
            <.icon name="hero-face-smile" class={@icon_size} />
          </div>
        <% end %>
      <% end %>

      <%= if @show_save do %>
        <%= if @current_user do %>
          <button
            phx-click={if @is_saved, do: @on_unsave, else: @on_save}
            {[{"phx-value-#{@actual_save_value_name}", @actual_save_post_id}]}
            id={action_button_id(@dom_id_prefix, "save")}
            data-action-lock-key={action_lock_key(@dom_id_prefix, "save")}
            class={[
              "flex h-8 w-8 items-center justify-center rounded-md transition-all duration-150 cursor-pointer phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
              if(@is_saved,
                do: "text-primary phx-click-loading:text-base-content/60",
                else: "text-base-content/60 hover:text-primary phx-click-loading:text-primary"
              )
            ]}
            title={if @is_saved, do: "Remove from saved", else: "Save"}
            type="button"
          >
            <span class="inline-flex items-center">
              <.icon
                name={if @is_saved, do: "hero-bookmark-solid", else: "hero-bookmark"}
                class={[@icon_size, @is_saved && "text-primary"]}
              />
            </span>
          </button>
        <% else %>
          <div class="flex h-8 w-8 items-center justify-center rounded-md opacity-50 cursor-default">
            <.icon name="hero-bookmark" class={@icon_size} />
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  @doc """
  Standalone like button component.
  """
  attr :post_id, :any, required: true
  attr :is_liked, :boolean, default: false
  attr :like_count, :integer, default: 0
  attr :on_like, :string, default: "like_post"
  attr :on_unlike, :string, default: "unlike_post"
  attr :value_name, :string, default: "post_id"
  attr :icon_size, :string, default: "w-4 h-4"
  attr :show_count, :boolean, default: true

  def like_button(assigns) do
    ~H"""
    <button
      phx-click={if @is_liked, do: @on_unlike, else: @on_like}
      {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
      class={[
        "flex items-center gap-1.5 transition-all duration-150 phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
        if(@is_liked,
          do: "text-primary phx-click-loading:text-base-content/60",
          else: "text-base-content hover:text-primary phx-click-loading:text-primary"
        )
      ]}
      type="button"
    >
      <span class="inline-flex items-center gap-1.5">
        <.icon
          name={if @is_liked, do: "hero-heart-solid", else: "hero-heart"}
          class={[@icon_size, @is_liked && "text-primary"]}
        />
        <%= if @show_count do %>
          <span>{normalize_interaction_count(@like_count)}</span>
        <% end %>
      </span>
    </button>
    """
  end

  @doc """
  Standalone comment button component.
  """
  attr :post_id, :any, required: true
  attr :comment_count, :integer, default: 0
  attr :on_comment, :string, default: "show_reply_form"
  attr :value_name, :string, default: "post_id"
  attr :icon_size, :string, default: "w-4 h-4"
  attr :show_count, :boolean, default: true
  attr :label, :string, default: nil

  def comment_button(assigns) do
    ~H"""
    <button
      phx-click={@on_comment}
      {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
      class="flex items-center gap-1.5 text-base-content/60 hover:text-primary transition-colors phx-click-loading:pointer-events-none phx-click-loading:cursor-wait"
      type="button"
    >
      <.icon name="hero-chat-bubble-left" class={@icon_size} />
      <%= if @label do %>
        <span>{@label}</span>
      <% else %>
        <%= if @show_count do %>
          <span>{@comment_count}</span>
        <% end %>
      <% end %>
    </button>
    """
  end

  @doc """
  Standalone boost button component.
  """
  attr :post_id, :any, required: true
  attr :is_boosted, :boolean, default: false
  attr :boost_count, :integer, default: 0
  attr :on_boost, :string, default: "boost_post"
  attr :on_unboost, :string, default: "unboost_post"
  attr :value_name, :string, default: "post_id"
  attr :icon_size, :string, default: "w-4 h-4"
  attr :show_count, :boolean, default: true

  def boost_button(assigns) do
    ~H"""
    <button
      phx-click={if @is_boosted, do: @on_unboost, else: @on_boost}
      {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
      class={[
        "flex items-center gap-1.5 transition-all duration-150 phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
        if(@is_boosted,
          do: "text-accent phx-click-loading:text-base-content/60",
          else: "text-base-content/60 hover:text-accent phx-click-loading:text-accent"
        )
      ]}
      type="button"
    >
      <span class="inline-flex items-center gap-1.5">
        <.icon
          name={if @is_boosted, do: "hero-arrow-path-solid", else: "hero-arrow-path"}
          class={@icon_size}
        />
        <%= if @show_count do %>
          <span>{normalize_interaction_count(@boost_count)}</span>
        <% end %>
      </span>
    </button>
    """
  end

  @doc """
  Vote buttons for Reddit/Lemmy-style posts (upvote/downvote in vertical layout).

  This is the canonical vote component - use this across all discussion/community pages
  for consistent styling and behavior.

  ## Attributes

  * `:post_id` - The post identifier (can be integer ID or ActivityPub URI string)
  * `:current_user` - The current user (nil if not logged in)
  * `:is_upvoted` - Whether the current user has upvoted this post
  * `:is_downvoted` - Whether the current user has downvoted this post
  * `:score` - Net score (upvotes - downvotes)
  * `:on_vote` - Event name for vote action (default: "vote")
  * `:value_name` - The phx-value attribute name: "post_id" or "message_id" (default: "message_id")
  * `:size` - Size variant: :sm, :md, :lg (default: :md)
  * `:show_zero_score` - Whether to show a zero score between arrows (default: false)
  """
  attr :post_id, :any, required: true
  attr :current_user, :map, default: nil
  attr :is_upvoted, :boolean, default: false
  attr :is_downvoted, :boolean, default: false
  attr :score, :integer, default: 0
  attr :on_vote, :string, default: "vote"
  attr :value_name, :string, default: "message_id"
  attr :size, :atom, default: :md
  attr :show_zero_score, :boolean, default: false

  def vote_buttons(assigns) do
    {btn_class, icon_class, score_class} =
      case assigns.size do
        :sm ->
          {"inline-flex h-6 w-6 items-center justify-center rounded-md border border-transparent p-1",
           "w-3 h-3 sm:w-4 sm:h-4 transition-none", "text-xs font-bold"}

        :md ->
          {"inline-flex h-7 w-7 items-center justify-center rounded-md border border-transparent p-1 sm:h-8 sm:w-8 sm:p-2",
           "w-4 h-4 sm:w-5 sm:h-5 transition-none", "text-sm font-bold"}

        :lg ->
          {"inline-flex h-9 w-9 items-center justify-center rounded-md border border-transparent p-2",
           "w-5 h-5 transition-none", "text-base font-bold"}

        _ ->
          {"inline-flex h-7 w-7 items-center justify-center rounded-md border border-transparent p-1 sm:h-8 sm:w-8 sm:p-2",
           "w-4 h-4 sm:w-5 sm:h-5 transition-none", "text-sm font-bold"}
      end

    assigns =
      assigns
      |> assign(:btn_class, btn_class)
      |> assign(:icon_class, icon_class)
      |> assign(:score_class, score_class)
      |> assign(
        :show_score,
        assigns.show_zero_score || assigns.score != 0 || assigns.is_upvoted ||
          assigns.is_downvoted
      )

    ~H"""
    <div
      class="flex flex-col items-center gap-1 flex-shrink-0"
      role="group"
      aria-label="Voting"
    >
      <%= if @current_user do %>
        <button
          phx-click={@on_vote}
          phx-value-message_id={if @value_name == "message_id", do: @post_id}
          phx-value-post_id={if @value_name == "post_id", do: @post_id}
          phx-value-type="up"
          class={[
            @btn_class,
            "vote-up-button transition-all duration-150 phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
            if(@is_upvoted,
              do:
                "bg-secondary/20 text-secondary hover:bg-secondary/30 phx-click-loading:bg-transparent phx-click-loading:text-base-content/70",
              else:
                "text-base-content/50 hover:bg-secondary/20 hover:text-secondary phx-click-loading:bg-secondary/20 phx-click-loading:text-secondary"
            )
          ]}
          aria-label={if @is_upvoted, do: "Remove upvote", else: "Upvote"}
          aria-pressed={@is_upvoted}
          type="button"
        >
          <span class="inline-flex phx-click-loading:hidden">
            <.icon
              name={if @is_upvoted, do: "hero-arrow-up-solid", else: "hero-arrow-up"}
              class={@icon_class}
            />
          </span>
          <span class="hidden phx-click-loading:inline-flex" aria-hidden="true">
            <.icon
              name={if @is_upvoted, do: "hero-arrow-up", else: "hero-arrow-up-solid"}
              class={@icon_class}
            />
          </span>
        </button>
      <% else %>
        <div class={"#{@btn_class} opacity-50 cursor-not-allowed"}>
          <.icon name="hero-arrow-up" class={@icon_class} />
        </div>
      <% end %>

      <span
        class={[
          "vote-score",
          !@show_score && "vote-score--empty",
          @score_class,
          cond do
            @is_upvoted -> "text-secondary"
            @is_downvoted -> "text-error"
            true -> ""
          end
        ]}
        aria-label={if @show_score, do: "Score: #{@score}"}
      >
        <span class="vote-score-current">{@score}</span>
        <span class="vote-score-pending hidden" aria-hidden="true">
          {@score + if(@is_upvoted, do: -1, else: if(@is_downvoted, do: 2, else: 1))}
        </span>
      </span>

      <%= if @current_user do %>
        <button
          phx-click={@on_vote}
          phx-value-message_id={if @value_name == "message_id", do: @post_id}
          phx-value-post_id={if @value_name == "post_id", do: @post_id}
          phx-value-type="down"
          class={[
            @btn_class,
            "transition-none phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
            if(@is_downvoted,
              do: "bg-error/20 text-error hover:bg-error/30",
              else: "text-base-content/50 hover:bg-error/20 hover:text-error"
            )
          ]}
          aria-label={if @is_downvoted, do: "Remove downvote", else: "Downvote"}
          aria-pressed={@is_downvoted}
          type="button"
        >
          <.icon
            name={if @is_downvoted, do: "hero-arrow-down-solid", else: "hero-arrow-down"}
            class={@icon_class}
          />
        </button>
      <% else %>
        <div class={"#{@btn_class} opacity-50 cursor-not-allowed"}>
          <.icon name="hero-arrow-down" class={@icon_class} />
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Standalone save/bookmark button component.
  """
  attr :post_id, :any, required: true
  attr :is_saved, :boolean, default: false
  attr :on_save, :string, default: "save_post"
  attr :on_unsave, :string, default: "unsave_post"
  attr :value_name, :string, default: "post_id"
  attr :icon_size, :string, default: "w-4 h-4"

  def save_button(assigns) do
    ~H"""
    <button
      phx-click={if @is_saved, do: @on_unsave, else: @on_save}
      {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
      class={[
        "flex h-8 w-8 items-center justify-center rounded-md transition-all duration-150 phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
        if(@is_saved,
          do: "text-primary phx-click-loading:text-base-content/60",
          else: "text-base-content/60 hover:text-primary phx-click-loading:text-primary"
        )
      ]}
      title={if @is_saved, do: "Remove from saved", else: "Save"}
      type="button"
    >
      <span class="inline-flex items-center">
        <.icon
          name={if @is_saved, do: "hero-bookmark-solid", else: "hero-bookmark"}
          class={[@icon_size, @is_saved && "text-primary"]}
        />
      </span>
    </button>
    """
  end

  defp action_button_id(nil, action), do: "post-action-#{action}"
  defp action_button_id(prefix, action), do: "#{prefix}-#{action}"

  defp count_id(prefix, action), do: "#{action_button_id(prefix, action)}-count"
  defp action_lock_key(prefix, action), do: "#{action_button_id(prefix, action)}-lock"

  defp reaction_value_attrs(value_name, post_id, emoji, actor_uri) do
    [{"phx-value-#{value_name}", post_id}, {"phx-value-emoji", emoji}] ++
      reaction_actor_uri_attr(actor_uri)
  end

  defp reaction_actor_uri_attr(actor_uri) when is_binary(actor_uri) do
    case String.trim(actor_uri) do
      "" -> []
      trimmed -> [{"phx-value-actor_uri", trimmed}]
    end
  end

  defp reaction_actor_uri_attr(_), do: []

  defp user_reacted?(reactions, current_user, emoji)
       when is_list(reactions) and is_map(current_user) do
    Enum.any?(reactions, fn
      %{emoji: ^emoji, user_id: user_id} -> user_id == current_user.id
      %{"emoji" => ^emoji, "user_id" => user_id} -> user_id == current_user.id
      _ -> false
    end)
  end

  defp user_reacted?(_, _, _), do: false

  defp user_reacted_any?(reactions, current_user, emojis) when is_list(emojis) do
    Enum.any?(emojis, &user_reacted?(reactions, current_user, &1))
  end

  defp user_reacted_any?(_, _, _), do: false

  attr :id, :string, required: true
  attr :class, :any, default: nil
  attr :count, :any, required: true
  attr :loading, :boolean, default: false

  defp animated_count(assigns) do
    assigns =
      assigns
      |> assign(:count_value, normalize_interaction_count(assigns.count))
      |> assign(:count_known?, is_integer(assigns.count))

    ~H"""
    <%= if @loading && !@count_known? do %>
      <span
        id={@id}
        class={[@class, "inline-block min-w-[2ch] text-base-content/45"]}
        aria-busy="true"
      >
        --
      </span>
    <% else %>
      <span
        id={@id}
        class={@class}
        phx-hook="AnimatedCount"
        phx-update="ignore"
        data-count={@count_value}
      >
        {@count_value}
      </span>
    <% end %>
    """
  end

  defp default_dom_id_prefix(assigns) do
    digest =
      :erlang.phash2({
        assigns.post_id,
        assigns.value_name,
        assigns.size,
        assigns.style,
        assigns.comment_path,
        assigns.on_like,
        assigns.on_boost,
        assigns.on_save
      })

    "post-actions-#{digest}"
  end

  defp normalize_interaction_count(count) when is_integer(count), do: max(count, 0)
  defp normalize_interaction_count(_), do: 0
end
