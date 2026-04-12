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
  attr :show_comment, :boolean, default: true
  attr :show_boost, :boolean, default: true
  attr :show_quote, :boolean, default: true
  attr :show_like, :boolean, default: true
  attr :show_save, :boolean, default: true
  attr :is_saved, :boolean, default: false
  attr :quote_count, :integer, default: 0
  attr :value_name, :string, default: "post_id"
  attr :comment_value_name, :string, default: nil
  attr :comment_path, :string, default: nil
  attr :size, :atom, default: :sm
  attr :style, :atom, default: :default

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

    # Use comment_value_name if set, otherwise fall back to value_name
    actual_comment_value_name = assigns.comment_value_name || assigns.value_name

    assigns =
      assigns
      |> assign(:icon_size, icon_size)
      |> assign(:btn_class, btn_class)
      |> assign(:text_class, text_class)
      |> assign(:actual_comment_value_name, actual_comment_value_name)

    if assigns.style == :minimal do
      render_minimal(assigns)
    else
      render_default(assigns)
    end
  end

  defp render_default(assigns) do
    ~H"""
    <div class="flex items-center gap-1 post-actions-container">
      <%= if @show_like do %>
        <%= if @current_user do %>
          <button
            phx-click={if @is_liked, do: @on_unlike, else: @on_like}
            {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
            class={[
              @btn_class,
              "cursor-pointer transition-all duration-150 phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
              @is_liked &&
                "bg-secondary/10 text-secondary phx-click-loading:bg-transparent phx-click-loading:text-base-content/70",
              !@is_liked && "phx-click-loading:bg-secondary/10 phx-click-loading:text-secondary"
            ]}
            type="button"
          >
            <span class="inline-flex items-center gap-1">
              <.icon
                name={if @is_liked, do: "hero-heart-solid", else: "hero-heart"}
                class={[@icon_size, @is_liked && "text-secondary"]}
              />
              <span class={@text_class}>{normalize_interaction_count(@like_count)}</span>
            </span>
          </button>
        <% else %>
          <div class={[@btn_class, "cursor-default opacity-60"]}>
            <.icon name="hero-heart" class={@icon_size} />
            <span class={@text_class}>{@like_count}</span>
          </div>
        <% end %>
      <% end %>

      <%= if @show_comment do %>
        <%= if @comment_path do %>
          <.link
            navigate={@comment_path}
            class={[
              @btn_class,
              "cursor-pointer transition-colors"
            ]}
          >
            <.icon name="hero-chat-bubble-left" class={@icon_size} />
            <span class={@text_class}>{@comment_count}</span>
          </.link>
        <% else %>
          <%= if @current_user do %>
            <button
              phx-click={@on_comment}
              {[{"phx-value-#{@actual_comment_value_name}", @post_id}]}
              class={[
                @btn_class,
                "cursor-pointer transition-colors phx-click-loading:pointer-events-none phx-click-loading:cursor-wait"
              ]}
              type="button"
            >
              <.icon name="hero-chat-bubble-left" class={@icon_size} />
              <span class={@text_class}>{@comment_count}</span>
            </button>
          <% else %>
            <div class={[@btn_class, "cursor-default opacity-60"]}>
              <.icon name="hero-chat-bubble-left" class={@icon_size} />
              <span class={@text_class}>{@comment_count}</span>
            </div>
          <% end %>
        <% end %>
      <% end %>

      <%= if @show_boost do %>
        <%= if @current_user do %>
          <button
            phx-click={if @is_boosted, do: @on_unboost, else: @on_boost}
            {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
            class={[
              @btn_class,
              "cursor-pointer transition-all duration-150 phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
              @is_boosted &&
                "bg-success/10 text-success phx-click-loading:bg-transparent phx-click-loading:text-base-content/70",
              !@is_boosted && "phx-click-loading:bg-success/10 phx-click-loading:text-success"
            ]}
            type="button"
            title={if @is_boosted, do: "Unboost", else: "Boost"}
          >
            <span class="inline-flex items-center gap-1">
              <.icon
                name={if @is_boosted, do: "hero-arrow-path-solid", else: "hero-arrow-path"}
                class={[@icon_size, @is_boosted && "text-success"]}
              />
              <span class={@text_class}>{normalize_interaction_count(@boost_count)}</span>
            </span>
          </button>
        <% else %>
          <div class={[@btn_class, "cursor-default opacity-60"]}>
            <.icon name="hero-arrow-path" class={@icon_size} />
            <span class={@text_class}>{@boost_count}</span>
          </div>
        <% end %>
      <% end %>

      <%= if @show_quote do %>
        <%= if @current_user do %>
          <button
            phx-click={@on_quote}
            {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
            class={[
              @btn_class,
              "cursor-pointer hidden sm:flex transition-colors phx-click-loading:pointer-events-none phx-click-loading:cursor-wait"
            ]}
            type="button"
            title="Quote post"
          >
            <.icon name="hero-chat-bubble-bottom-center-text" class={@icon_size} />
            <span class={@text_class}>{@quote_count}</span>
          </button>
        <% else %>
          <div class={[@btn_class, "cursor-default opacity-60 hidden sm:flex"]}>
            <.icon name="hero-chat-bubble-bottom-center-text" class={@icon_size} />
            <span class={@text_class}>{@quote_count}</span>
          </div>
        <% end %>
      <% end %>

      <%= if @show_save do %>
        <%= if @current_user do %>
          <button
            phx-click={if @is_saved, do: @on_unsave, else: @on_save}
            {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
            class={[
              @btn_class,
              "cursor-pointer transition-all duration-150 phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
              @is_saved &&
                "bg-warning/10 text-warning phx-click-loading:bg-transparent phx-click-loading:text-base-content/70",
              !@is_saved && "phx-click-loading:bg-warning/10 phx-click-loading:text-warning"
            ]}
            type="button"
            title={if @is_saved, do: "Remove from saved", else: "Save"}
          >
            <span class="inline-flex items-center">
              <.icon
                name={if @is_saved, do: "hero-bookmark-solid", else: "hero-bookmark"}
                class={[@icon_size, @is_saved && "text-warning"]}
              />
            </span>
          </button>
        <% else %>
          <div class={[@btn_class, "cursor-default opacity-60"]}>
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
            class={[
              "flex items-center gap-1.5 transition-all duration-150 cursor-pointer phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
              if(@is_liked,
                do: "text-secondary phx-click-loading:text-base-content/60",
                else: "text-base-content/60 hover:text-secondary phx-click-loading:text-secondary"
              )
            ]}
            type="button"
          >
            <span class="inline-flex items-center gap-1.5">
              <.icon
                name={if @is_liked, do: "hero-heart-solid", else: "hero-heart"}
                class={[@icon_size, @is_liked && "text-secondary"]}
              />
              <span>{normalize_interaction_count(@like_count)}</span>
            </span>
          </button>
        <% else %>
          <div class="flex items-center gap-1.5 opacity-50 cursor-default">
            <.icon name="hero-heart" class={@icon_size} />
            <span>{@like_count}</span>
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
            <span>{@comment_count}</span>
          </.link>
        <% end %>
        <%= if !@comment_path do %>
          <%= if @current_user do %>
            <button
              phx-click={@on_comment}
              {[{"phx-value-#{@actual_comment_value_name}", @post_id}]}
              class="flex items-center gap-1.5 text-base-content/60 hover:text-primary transition-colors cursor-pointer phx-click-loading:pointer-events-none phx-click-loading:cursor-wait"
              type="button"
            >
              <.icon name="hero-chat-bubble-left" class={@icon_size} />
              <span>{@comment_count}</span>
            </button>
          <% else %>
            <div class="flex items-center gap-1.5 opacity-50 cursor-default">
              <.icon name="hero-chat-bubble-left" class={@icon_size} />
              <span>{@comment_count}</span>
            </div>
          <% end %>
        <% end %>
      <% end %>

      <%= if @show_boost do %>
        <%= if @current_user do %>
          <button
            phx-click={if @is_boosted, do: @on_unboost, else: @on_boost}
            {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
            class={[
              "flex items-center gap-1.5 transition-all duration-150 cursor-pointer phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
              if(@is_boosted,
                do: "text-success phx-click-loading:text-base-content/60",
                else: "text-base-content/60 phx-click-loading:text-success"
              )
            ]}
            type="button"
          >
            <span class="inline-flex items-center gap-1.5">
              <.icon
                name={if @is_boosted, do: "hero-arrow-path-solid", else: "hero-arrow-path"}
                class={@icon_size}
              />
              <span>{normalize_interaction_count(@boost_count)}</span>
            </span>
          </button>
        <% else %>
          <div class="flex items-center gap-1.5 opacity-50 cursor-default">
            <.icon name="hero-arrow-path" class={@icon_size} />
            <span>{@boost_count}</span>
          </div>
        <% end %>
      <% end %>

      <%= if @show_save do %>
        <%= if @current_user do %>
          <button
            phx-click={if @is_saved, do: @on_unsave, else: @on_save}
            {@value_name == "message_id" && [{"phx-value-message_id", @post_id}] || [{"phx-value-post_id", @post_id}]}
            class={[
              "flex items-center gap-1.5 transition-all duration-150 cursor-pointer phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
              if(@is_saved,
                do: "text-warning phx-click-loading:text-base-content/60",
                else: "text-base-content/60 hover:text-warning phx-click-loading:text-warning"
              )
            ]}
            title={if @is_saved, do: "Remove from saved", else: "Save"}
            type="button"
          >
            <span class="inline-flex items-center">
              <.icon
                name={if @is_saved, do: "hero-bookmark-solid", else: "hero-bookmark"}
                class={[@icon_size, @is_saved && "text-warning"]}
              />
            </span>
          </button>
        <% else %>
          <div class="flex items-center gap-1.5 opacity-50 cursor-default">
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
          do: "text-secondary phx-click-loading:text-base-content/60",
          else: "text-base-content/60 hover:text-secondary phx-click-loading:text-secondary"
        )
      ]}
      type="button"
    >
      <span class="inline-flex items-center gap-1.5">
        <.icon
          name={if @is_liked, do: "hero-heart-solid", else: "hero-heart"}
          class={[@icon_size, @is_liked && "text-secondary"]}
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
          do: "text-success phx-click-loading:text-base-content/60",
          else: "text-base-content/60 phx-click-loading:text-success"
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
  """
  attr :post_id, :any, required: true
  attr :current_user, :map, default: nil
  attr :is_upvoted, :boolean, default: false
  attr :is_downvoted, :boolean, default: false
  attr :score, :integer, default: 0
  attr :on_vote, :string, default: "vote"
  attr :value_name, :string, default: "message_id"
  attr :size, :atom, default: :md

  def vote_buttons(assigns) do
    {btn_class, icon_class, score_class} =
      case assigns.size do
        :sm ->
          {"btn btn-ghost btn-xs p-1 min-h-0 h-6 w-6", "w-3 h-3 sm:w-4 sm:h-4",
           "text-xs font-bold"}

        :md ->
          {"btn btn-ghost btn-xs sm:btn-sm p-1 sm:p-2 min-h-0 h-7 sm:h-8 w-7 sm:w-8",
           "w-4 h-4 sm:w-5 sm:h-5", "text-sm font-bold"}

        :lg ->
          {"btn btn-ghost btn-sm p-2 min-h-0 h-9 w-9", "w-5 h-5", "text-base font-bold"}

        _ ->
          {"btn btn-ghost btn-xs sm:btn-sm p-1 sm:p-2 min-h-0 h-7 sm:h-8 w-7 sm:w-8",
           "w-4 h-4 sm:w-5 sm:h-5", "text-sm font-bold"}
      end

    assigns =
      assigns
      |> assign(:btn_class, btn_class)
      |> assign(:icon_class, icon_class)
      |> assign(:score_class, score_class)

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
            "transition-colors phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
            if(@is_upvoted,
              do: "bg-secondary/20 text-secondary hover:bg-secondary/30",
              else: "text-base-content/50 hover:bg-secondary/20 hover:text-secondary"
            )
          ]}
          aria-label={if @is_upvoted, do: "Remove upvote", else: "Upvote"}
          aria-pressed={@is_upvoted}
          type="button"
        >
          <.icon
            name={if @is_upvoted, do: "hero-arrow-up-solid", else: "hero-arrow-up"}
            class={@icon_class}
          />
        </button>
      <% else %>
        <div class={"#{@btn_class} opacity-50 cursor-not-allowed"}>
          <.icon name="hero-arrow-up" class={@icon_class} />
        </div>
      <% end %>

      <span
        class={[
          @score_class,
          cond do
            @is_upvoted -> "text-secondary"
            @is_downvoted -> "text-error"
            true -> ""
          end
        ]}
        aria-label={"Score: #{@score}"}
      >
        {@score}
      </span>

      <%= if @current_user do %>
        <button
          phx-click={@on_vote}
          phx-value-message_id={if @value_name == "message_id", do: @post_id}
          phx-value-post_id={if @value_name == "post_id", do: @post_id}
          phx-value-type="down"
          class={[
            @btn_class,
            "transition-colors phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
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
        "flex items-center gap-1.5 transition-all duration-150 phx-click-loading:scale-95 phx-click-loading:opacity-80 phx-click-loading:pointer-events-none phx-click-loading:cursor-wait",
        if(@is_saved,
          do: "text-warning phx-click-loading:text-base-content/60",
          else: "text-base-content/60 hover:text-warning phx-click-loading:text-warning"
        )
      ]}
      title={if @is_saved, do: "Remove from saved", else: "Save"}
      type="button"
    >
      <span class="inline-flex items-center">
        <.icon
          name={if @is_saved, do: "hero-bookmark-solid", else: "hero-bookmark"}
          class={[@icon_size, @is_saved && "text-warning"]}
        />
      </span>
    </button>
    """
  end

  defp normalize_interaction_count(count) when is_integer(count), do: max(count, 0)
  defp normalize_interaction_count(_), do: 0
end
