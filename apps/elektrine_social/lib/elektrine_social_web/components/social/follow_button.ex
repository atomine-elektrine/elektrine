defmodule ElektrineSocialWeb.Components.Social.FollowButton do
  @moduledoc """
  Shared follow button components for local users.
  """
  use ElektrineSocialWeb, :html

  attr :user_id, :integer, required: true
  attr :user_follows, :map, default: %{}
  attr :variant, :string, default: "timeline"
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def local_follow_button(assigns) do
    is_following = local_following?(assigns.user_follows, assigns.user_id)

    {button_classes, content_classes, icon_classes, label_classes} =
      local_follow_button_classes(assigns.variant, is_following)

    assigns =
      assigns
      |> assign(:is_following, is_following)
      |> assign(:button_classes, button_classes)
      |> assign(:content_classes, content_classes)
      |> assign(:icon_classes, icon_classes)
      |> assign(:label_classes, label_classes)

    ~H"""
    <button
      id={@id}
      phx-click="toggle_follow"
      phx-value-user_id={@user_id}
      class={[@button_classes, @class]}
      type="button"
    >
      <span class={@content_classes}>
        <%= if @is_following do %>
          <.icon name="hero-user-minus" class={@icon_classes} />
          <span class={@label_classes}>Unfollow</span>
        <% else %>
          <.icon name="hero-user-plus" class={@icon_classes} />
          <span class={@label_classes}>Follow</span>
        <% end %>
      </span>
    </button>
    """
  end

  defp local_following?(user_follows, user_id) do
    Map.get(user_follows, {:local, user_id}, false) || Map.get(user_follows, user_id, false)
  end

  defp local_follow_button_classes("card", is_following) do
    {
      [
        "btn btn-sm w-full phx-click-loading:pointer-events-none phx-click-loading:cursor-wait phx-click-loading:opacity-70",
        if(is_following,
          do: "btn-ghost",
          else: "btn-primary phx-click-loading:bg-base-200 phx-click-loading:text-base-content"
        )
      ],
      "inline-flex items-center justify-center",
      "w-4 h-4 mr-1",
      nil
    }
  end

  defp local_follow_button_classes(_, is_following) do
    {
      [
        "btn btn-xs px-1.5 h-7 min-h-0 sm:px-2 sm:btn-sm phx-click-loading:pointer-events-none phx-click-loading:cursor-wait phx-click-loading:opacity-70",
        if(is_following,
          do: "btn-ghost",
          else: "btn-secondary phx-click-loading:bg-base-200 phx-click-loading:text-base-content"
        )
      ],
      "inline-flex items-center",
      "w-3 h-3 sm:w-4 sm:h-4",
      "text-[10px] sm:text-sm ml-0.5 sm:ml-1 hidden min-[320px]:inline"
    }
  end
end
