defmodule ElektrineWeb.Components.Social.OverviewStreamPost do
  @moduledoc """
  Stateful wrapper for a single overview feed entry.
  """

  use ElektrineWeb, :live_component

  import ElektrineWeb.Components.Social.TimelinePost, only: [timeline_post: 1]

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"overview-stream-post-body-#{@post.id}"}>
      <.timeline_post
        post={@post}
        current_user={@current_user}
        timezone={@timezone}
        time_format={@time_format}
        user_likes={@user_likes}
        user_boosts={@user_boosts}
        user_saves={@user_saves}
        user_follows={@user_follows}
        pending_follows={@pending_follows}
        user_statuses={@user_statuses}
        post_reactions_map={@post_reactions}
        reactions={Map.get(@post_reactions, @post.id, [])}
        resolve_reply_refs={true}
        on_image_click="open_image_modal"
        source="overview"
      />
    </div>
    """
  end
end
