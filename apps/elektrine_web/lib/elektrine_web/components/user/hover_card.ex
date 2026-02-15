defmodule ElektrineWeb.Components.User.HoverCard do
  @moduledoc """
  User hover card component that shows profile details on hover.
  """
  use ElektrineWeb, :html
  import ElektrineWeb.Components.User.Avatar
  import ElektrineWeb.Components.User.UsernameEffects
  import ElektrineWeb.HtmlHelpers, only: [render_display_name_with_emojis: 2]

  @doc """
  Renders a hoverable element that shows a user profile card on hover.

  ## Examples

      <.user_hover_card user={@user}>
        <span>@username</span>
      </.user_hover_card>

      <.user_hover_card remote_actor={@remote_actor}>
        <img src={@avatar} />
      </.user_hover_card>
  """
  attr :user, :map, default: nil, doc: "Local user struct"
  attr :remote_actor, :map, default: nil, doc: "Remote actor struct"
  attr :class, :string, default: "", doc: "Additional CSS classes for wrapper"
  attr :card_position, :string, default: "bottom", doc: "Card position: top, bottom"
  attr :user_statuses, :map, default: %{}, doc: "User online statuses"
  attr :user_follows, :map, default: %{}, doc: "Map of followed users"
  attr :pending_follows, :map, default: %{}, doc: "Map of pending follow requests"
  attr :current_user, :map, default: nil, doc: "Current logged in user"
  slot :inner_block, required: true

  def user_hover_card(assigns) do
    ~H"""
    <div
      class={["relative inline-block", @class]}
      phx-hook="UserHoverCard"
      id={generate_hover_id(assigns)}
    >
      <div data-hover-trigger>
        {render_slot(@inner_block)}
      </div>
      <div
        data-hover-card
        class={[
          "absolute z-[100] scale-95 opacity-0 invisible",
          "transition-all duration-150 ease-out origin-top-left",
          card_position_classes(@card_position)
        ]}
      >
        <div class="bg-base-100 border border-base-300 rounded-xl shadow-2xl p-4 w-72 mt-2">
          <%= if @user do %>
            <.local_user_card
              user={@user}
              user_statuses={@user_statuses}
              user_follows={@user_follows}
              current_user={@current_user}
            />
          <% else %>
            <.remote_user_card
              remote_actor={@remote_actor}
              user_follows={@user_follows}
              pending_follows={@pending_follows}
              current_user={@current_user}
            />
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp generate_hover_id(assigns) do
    unique = :erlang.unique_integer([:positive])

    cond do
      assigns[:user] -> "hover-user-#{assigns.user.id}-#{unique}"
      assigns[:remote_actor] -> "hover-remote-#{assigns.remote_actor.id}-#{unique}"
      true -> "hover-#{unique}"
    end
  end

  defp card_position_classes("top"), do: "bottom-full left-0 mb-2"
  defp card_position_classes("bottom"), do: "top-full left-0"
  defp card_position_classes("left"), do: "right-full top-0 mr-2"
  defp card_position_classes("right"), do: "left-full top-0 ml-2"
  defp card_position_classes(_), do: "top-full left-0"

  # Local user card
  defp local_user_card(assigns) do
    is_self = assigns.current_user && assigns.current_user.id == assigns.user.id
    is_following = Map.get(assigns.user_follows, {:local, assigns.user.id}, false)
    assigns = assigns |> assign(:is_self, is_self) |> assign(:is_following, is_following)

    ~H"""
    <div class="flex flex-col gap-3">
      <!-- Header with avatar and name -->
      <div class="flex items-start gap-3">
        <.link navigate={~p"/#{@user.handle || @user.username}"} class="flex-shrink-0">
          <.user_avatar user={@user} size="lg" user_statuses={@user_statuses} />
        </.link>
        <div class="flex-1 min-w-0">
          <.link navigate={~p"/#{@user.handle || @user.username}"} class="block">
            <.username_with_effects
              user={@user}
              display_name={true}
              verified_size="sm"
              class="font-semibold"
            />
          </.link>
          <div class="text-sm opacity-60 truncate">@{@user.handle || @user.username}@z.org</div>
        </div>
      </div>
      
    <!-- Bio -->
      <%= if desc = get_profile_description(@user) do %>
        <p class="text-sm line-clamp-3">{desc}</p>
      <% end %>
      
    <!-- Stats -->
      <div class="flex gap-4 text-sm">
        <div>
          <span class="font-semibold">{format_count(get_following_count(@user))}</span>
          <span class="opacity-60">Following</span>
        </div>
        <div>
          <span class="font-semibold">{format_count(get_follower_count(@user))}</span>
          <span class="opacity-60">Followers</span>
        </div>
      </div>
      
    <!-- Join date -->
      <div class="text-xs opacity-50">
        Joined {Calendar.strftime(@user.inserted_at, "%B %Y")}
      </div>
      
    <!-- Follow button -->
      <%= if @current_user && !@is_self do %>
        <button
          phx-click="toggle_follow"
          phx-value-user_id={@user.id}
          class={[
            "btn btn-sm w-full",
            if(@is_following, do: "btn-ghost", else: "btn-primary")
          ]}
        >
          <%= if @is_following do %>
            <.icon name="hero-user-minus" class="w-4 h-4 mr-1" /> Unfollow
          <% else %>
            <.icon name="hero-user-plus" class="w-4 h-4 mr-1" /> Follow
          <% end %>
        </button>
      <% end %>
    </div>
    """
  end

  # Remote user card
  defp remote_user_card(assigns) do
    profile_url = "/remote/#{assigns.remote_actor.username}@#{assigns.remote_actor.domain}"
    is_following = Map.get(assigns.user_follows, {:remote, assigns.remote_actor.id}, false)
    is_pending = Map.get(assigns.pending_follows, {:remote, assigns.remote_actor.id}, false)
    remote_handle = "#{assigns.remote_actor.username}@#{assigns.remote_actor.domain}"

    assigns =
      assigns
      |> assign(:profile_url, profile_url)
      |> assign(:is_following, is_following)
      |> assign(:is_pending, is_pending)
      |> assign(:remote_handle, remote_handle)

    ~H"""
    <div class="flex flex-col gap-3">
      <!-- Header with avatar and name -->
      <div class="flex items-start gap-3">
        <.link navigate={@profile_url} class="flex-shrink-0">
          <%= if @remote_actor.avatar_url do %>
            <img src={@remote_actor.avatar_url} alt="" class="w-12 h-12 rounded-full object-cover" />
          <% else %>
            <.placeholder_avatar size="lg" />
          <% end %>
        </.link>
        <div class="flex-1 min-w-0">
          <.link navigate={@profile_url} class="block font-semibold truncate">
            {raw(
              render_display_name_with_emojis(
                @remote_actor.display_name || @remote_actor.username,
                @remote_actor.domain
              )
            )}
          </.link>
          <div class="text-sm opacity-60 truncate">
            @{@remote_actor.username}@{@remote_actor.domain}
          </div>
        </div>
      </div>
      
    <!-- Bio -->
      <%= if @remote_actor.summary && String.trim(strip_html(@remote_actor.summary)) != "" do %>
        <p class="text-sm line-clamp-3">{strip_html(@remote_actor.summary)}</p>
      <% end %>
      
    <!-- Stats if available -->
      <%= if Map.get(@remote_actor, :followers_count) || Map.get(@remote_actor, :following_count) do %>
        <div class="flex gap-4 text-sm">
          <%= if Map.get(@remote_actor, :following_count) do %>
            <div>
              <span class="font-semibold">
                {format_count(Map.get(@remote_actor, :following_count))}
              </span>
              <span class="opacity-60">Following</span>
            </div>
          <% end %>
          <%= if Map.get(@remote_actor, :followers_count) do %>
            <div>
              <span class="font-semibold">
                {format_count(Map.get(@remote_actor, :followers_count))}
              </span>
              <span class="opacity-60">Followers</span>
            </div>
          <% end %>
        </div>
      <% end %>
      
    <!-- Instance badge -->
      <div class="flex items-center gap-1 text-xs opacity-50">
        <.icon name="hero-globe-alt" class="w-3 h-3" />
        <span>{@remote_actor.domain}</span>
      </div>
      
    <!-- Follow button -->
      <%= if @current_user do %>
        <button
          phx-click="toggle_follow_remote"
          phx-value-remote_actor_id={@remote_actor.id}
          disabled={@is_pending}
          class={[
            "btn btn-sm w-full",
            cond do
              @is_pending -> "btn-disabled"
              @is_following -> "btn-ghost"
              true -> "btn-primary"
            end
          ]}
        >
          <%= cond do %>
            <% @is_pending -> %>
              <.spinner size="sm" class="mr-1" /> Pending
            <% @is_following -> %>
              <.icon name="hero-user-minus" class="w-4 h-4 mr-1" /> Unfollow
            <% true -> %>
              <.icon name="hero-user-plus" class="w-4 h-4 mr-1" /> Follow
          <% end %>
        </button>
      <% end %>
    </div>
    """
  end

  defp get_following_count(user) do
    case user do
      %{profile: %{following_count: count}} when is_integer(count) -> count
      _ -> 0
    end
  end

  defp get_follower_count(user) do
    case user do
      %{profile: %{followers_count: count}} when is_integer(count) -> count
      _ -> 0
    end
  end

  defp format_count(nil), do: "0"

  defp format_count(count) when count >= 1_000_000 do
    "#{Float.round(count / 1_000_000, 1)}M"
  end

  defp format_count(count) when count >= 1_000 do
    "#{Float.round(count / 1_000, 1)}K"
  end

  defp format_count(count), do: to_string(count)

  defp strip_html(nil), do: ""

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace(~r/&[a-zA-Z]+;/, " ")
    |> String.trim()
  end

  defp strip_html(_), do: ""

  defp get_profile_description(user) do
    case user do
      %{profile: %{description: desc}} when is_binary(desc) and desc != "" -> String.trim(desc)
      _ -> nil
    end
  end
end
