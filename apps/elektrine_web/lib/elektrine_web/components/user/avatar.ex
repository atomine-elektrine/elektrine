defmodule ElektrineWeb.Components.User.Avatar do
  @moduledoc """
  Reusable avatar component with beautiful Hero icon fallbacks.
  """
  use Phoenix.Component
  import ElektrineWeb.CoreComponents

  @doc """
  Renders a placeholder avatar with consistent styling.
  Use this for remote actors, empty states, or anywhere a placeholder is needed.

  ## Examples

      <.placeholder_avatar size="sm" />
      <.placeholder_avatar size="lg" class="ring ring-primary" />
      <.placeholder_avatar size="xl" icon="hero-user-group" />
  """
  attr :size, :string, default: "md", doc: "Avatar size: xs, sm, md, lg, xl, 2xl, 3xl, profile"
  attr :icon, :string, default: "hero-user", doc: "Hero icon name to display"
  attr :class, :string, default: "", doc: "Additional CSS classes"
  attr :rest, :global, doc: "Additional HTML attributes"

  def placeholder_avatar(assigns) do
    ~H"""
    <div
      class={[
        "bg-gradient-to-br from-purple-600 to-purple-800 text-white rounded-full flex items-center justify-center flex-shrink-0",
        placeholder_size_classes(@size),
        @class
      ]}
      {@rest}
    >
      <.icon name={@icon} class={placeholder_icon_size(@size)} />
    </div>
    """
  end

  defp placeholder_size_classes("xs"), do: "w-6 h-6"
  defp placeholder_size_classes("sm"), do: "w-8 h-8"
  defp placeholder_size_classes("md"), do: "w-10 h-10"
  defp placeholder_size_classes("lg"), do: "w-12 h-12"
  defp placeholder_size_classes("xl"), do: "w-16 h-16"
  defp placeholder_size_classes("2xl"), do: "w-20 h-20"
  defp placeholder_size_classes("3xl"), do: "w-24 h-24"
  defp placeholder_size_classes("profile"), do: "w-24 h-24 sm:w-32 sm:h-32"
  defp placeholder_size_classes(_), do: "w-10 h-10"

  defp placeholder_icon_size("xs"), do: "w-4 h-4"
  defp placeholder_icon_size("sm"), do: "w-5 h-5"
  defp placeholder_icon_size("md"), do: "w-6 h-6"
  defp placeholder_icon_size("lg"), do: "w-8 h-8"
  defp placeholder_icon_size("xl"), do: "w-10 h-10"
  defp placeholder_icon_size("2xl"), do: "w-12 h-12"
  defp placeholder_icon_size("3xl"), do: "w-14 h-14"
  defp placeholder_icon_size("profile"), do: "w-16 h-16"
  defp placeholder_icon_size(_), do: "w-6 h-6"

  @doc """
  Renders a user avatar with automatic fallback to Hero icons.

  ## Examples

      <.user_avatar user={@user} size="sm" />
      <.user_avatar user={@user} size="lg" class="ring ring-primary" />
      <.user_avatar user={@user} size="xl" user_statuses={@user_statuses} />
  """
  attr :user, :map, required: true, doc: "User struct with avatar and username"
  attr :size, :string, default: "md", doc: "Avatar size: xs, sm, md, lg, xl, 2xl"
  attr :online_users, :list, default: [], doc: "List of online user IDs (as strings)"
  attr :user_statuses, :map, default: %{}, doc: "Map of user_id => %{status, message, devices}"
  attr :show_device, :boolean, default: false, doc: "Show device type indicator"
  attr :class, :string, default: "", doc: "Additional CSS classes"
  attr :rest, :global, doc: "Additional HTML attributes"

  def user_avatar(assigns) do
    # Get user status and device info from user_statuses map
    user_id = to_string(Map.get(assigns.user, :id))
    status_data = Map.get(assigns.user_statuses, user_id, %{})

    assigns =
      assigns
      |> assign(:computed_status, get_user_status(assigns))
      |> assign(:devices, Map.get(status_data, :devices, []))
      |> assign(:device_count, Map.get(status_data, :device_count, 0))

    ~H"""
    <div class="relative inline-block">
      <%= if @user && Map.get(@user, :avatar) do %>
        <img
          src={Elektrine.Uploads.avatar_url(@user.avatar)}
          alt={"#{Map.get(@user, :username, "User")} avatar"}
          class={["rounded-full object-cover", avatar_size_classes(@size), @class]}
          {@rest}
        />
      <% else %>
        <!-- Hero Icon Fallback -->
        <div
          class={[
            "bg-gradient-to-br from-purple-600 to-purple-800 text-white rounded-full relative",
            avatar_size_classes(@size),
            @class
          ]}
          {@rest}
        >
          <div class="absolute inset-0 flex items-center justify-center">
            <.icon name="hero-user" class={"#{hero_icon_size(@size)} block"} />
          </div>
        </div>
      <% end %>
      <%= if @computed_status do %>
        <span
          class={[
            "absolute -bottom-1 -right-1 rounded-full border-2 border-base-100 shadow-md flex items-center justify-center",
            status_color(@computed_status),
            if(@show_device && @device_count > 1, do: "w-5 h-5", else: "w-4 h-4")
          ]}
          title={device_tooltip(@devices, @device_count)}
        >
          <%= if @show_device && @device_count > 1 do %>
            <span class="text-[8px] font-bold text-white">{@device_count}</span>
          <% end %>
        </span>
      <% end %>
      <!-- Mobile device indicator -->
      <%= if @show_device && "mobile" in @devices && @computed_status not in [nil, "offline"] do %>
        <span
          class="absolute -top-1 -right-1 w-3 h-3 bg-base-100 rounded-full flex items-center justify-center"
          title="On mobile"
        >
          <.icon name="hero-device-phone-mobile" class="w-2 h-2 text-primary" />
        </span>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a conversation/group avatar with fallback icons.
  """
  attr :conversation, :map, required: true
  attr :current_user_id, :integer, required: true
  attr :size, :string, default: "md"
  attr :class, :string, default: ""
  attr :online_users, :list, default: []
  attr :user_statuses, :map, default: %{}
  attr :rest, :global

  def conversation_avatar(assigns) do
    ~H"""
    <%= cond do %>
      <% @conversation.type == "dm" -> %>
        <!-- For DMs, show the other user's avatar -->
        <% other_user = get_other_dm_user(@conversation, @current_user_id) %>
        <% user_status = other_user && Map.get(@user_statuses, to_string(other_user.id)) %>
        <% status =
          (user_status && user_status.status) ||
            if other_user && to_string(other_user.id) in @online_users, do: "online", else: nil %>
        <div class="relative inline-block">
          <%= if other_user && other_user.avatar do %>
            <img
              src={Elektrine.Uploads.avatar_url(other_user.avatar)}
              alt={"#{other_user.username} avatar"}
              class={["rounded-full object-cover", avatar_size_classes(@size), @class]}
              {@rest}
            />
          <% else %>
            <div
              class={[
                "bg-gradient-to-br from-purple-600 to-purple-800 text-white rounded-full relative",
                avatar_size_classes(@size),
                @class
              ]}
              {@rest}
            >
              <div class="absolute inset-0 flex items-center justify-center">
                <.icon name="hero-user" class={"#{hero_icon_size(@size)} block"} />
              </div>
            </div>
          <% end %>
          <%= if status do %>
            <span class={[
              "absolute -bottom-1 -right-1 w-4 h-4 rounded-full border-2 border-base-100 shadow-md",
              status_color(status)
            ]}>
            </span>
          <% end %>
        </div>
      <% @conversation.avatar_url -> %>
        <!-- Custom group/channel avatar -->
        <img
          src={@conversation.avatar_url}
          alt={"#{@conversation.name} avatar"}
          class={["rounded-full ", avatar_size_classes(@size), @class]}
          {@rest}
        />
      <% @conversation.type == "group" -> %>
        <!-- Group fallback -->
        <div
          class={[
            "bg-gradient-to-br from-purple-600 to-purple-800 text-white rounded-full relative",
            avatar_size_classes(@size),
            @class
          ]}
          {@rest}
        >
          <div class="absolute inset-0 flex items-center justify-center">
            <.icon name="hero-users" class={"#{hero_icon_size(@size)} block"} />
          </div>
        </div>
      <% @conversation.type == "channel" -> %>
        <!-- Channel fallback -->
        <div
          class={[
            "bg-gradient-to-br from-orange-500 to-orange-700 text-white rounded-full relative",
            avatar_size_classes(@size),
            @class
          ]}
          {@rest}
        >
          <div class="absolute inset-0 flex items-center justify-center">
            <.icon name="hero-megaphone" class={"#{hero_icon_size(@size)} block"} />
          </div>
        </div>
      <% true -> %>
        <!-- Default fallback -->
        <div
          class={[
            "bg-gradient-to-br from-purple-600 to-purple-800 text-white rounded-full relative",
            avatar_size_classes(@size),
            @class
          ]}
          {@rest}
        >
          <div class="absolute inset-0 flex items-center justify-center">
            <.icon name="hero-chat-bubble-left-right" class={"#{hero_icon_size(@size)} block"} />
          </div>
        </div>
    <% end %>
    """
  end

  # Private helper functions

  defp avatar_size_classes("xs"), do: "w-6 h-6"
  defp avatar_size_classes("sm"), do: "w-8 h-8"
  defp avatar_size_classes("md"), do: "w-10 h-10"
  defp avatar_size_classes("lg"), do: "w-12 h-12"
  defp avatar_size_classes("xl"), do: "w-16 h-16"
  defp avatar_size_classes("2xl"), do: "w-20 h-20"
  defp avatar_size_classes("responsive"), do: "w-10 sm:w-12 lg:w-12 h-10 sm:h-12 lg:h-12"
  defp avatar_size_classes(_), do: "w-10 h-10"

  defp hero_icon_size("xs"), do: "w-3 h-3"
  defp hero_icon_size("sm"), do: "w-4 h-4"
  defp hero_icon_size("md"), do: "w-5 h-5"
  defp hero_icon_size("lg"), do: "w-6 h-6"
  defp hero_icon_size("xl"), do: "w-8 h-8"
  defp hero_icon_size("2xl"), do: "w-10 h-10"
  defp hero_icon_size("responsive"), do: "w-4 h-4 sm:w-5 sm:h-5 lg:w-6 lg:h-6"
  defp hero_icon_size(_), do: "w-5 h-5"

  # Get user status from user_statuses map or online_users list
  defp get_user_status(assigns) do
    user_id = to_string(Map.get(assigns.user, :id))

    cond do
      map_size(assigns.user_statuses) > 0 && Map.has_key?(assigns.user_statuses, user_id) ->
        Map.get(assigns.user_statuses, user_id).status

      user_id in assigns.online_users ->
        "online"

      true ->
        nil
    end
  end

  # Map status to Tailwind color classes
  defp status_color("online"), do: "bg-success"
  defp status_color("away"), do: "bg-warning"
  defp status_color("dnd"), do: "bg-error"
  defp status_color("offline"), do: "bg-gray-400"
  defp status_color(_), do: "bg-success"

  # Generate tooltip for device indicators
  defp device_tooltip([], _count), do: nil
  defp device_tooltip(_devices, 0), do: nil
  defp device_tooltip(_devices, 1), do: nil

  defp device_tooltip(devices, count) do
    device_names =
      devices
      |> Enum.map(fn
        "mobile" -> "Mobile"
        "tablet" -> "Tablet"
        "desktop" -> "Desktop"
        other -> String.capitalize(other)
      end)
      |> Enum.map_join(", ", & &1)

    "Online on #{count} devices: #{device_names}"
  end

  defp get_other_dm_user(%{type: "dm", members: members}, current_user_id) do
    Enum.find(members, fn member ->
      member.user_id != current_user_id and is_nil(member.left_at)
    end)
    |> case do
      %{user: user} -> user
      nil -> nil
    end
  end

  defp get_other_dm_user(_, _), do: nil
end
