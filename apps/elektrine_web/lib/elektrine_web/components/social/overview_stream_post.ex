defmodule ElektrineWeb.Components.Social.OverviewStreamPost do
  @moduledoc """
  Stateful wrapper for a single overview feed entry.
  """

  use ElektrineWeb, :live_component

  import ElektrineWeb.Components.Social.TimelinePost, only: [timeline_post: 1]

  alias ElektrineWeb.Components.Social.PostUtilities

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :is_lemmy_post, PostUtilities.community_post?(assigns.post))

    ~H"""
    <div id={"overview-stream-post-body-#{@post.id}"}>
      <.timeline_post
        post={@post}
        layout={if @is_lemmy_post, do: :lemmy, else: :timeline}
        current_user={@current_user}
        timezone={@timezone}
        time_format={@time_format}
        user_likes={@user_likes}
        user_downvotes={%{}}
        user_boosts={@user_boosts}
        user_saves={@user_saves}
        user_follows={@user_follows}
        pending_follows={@pending_follows}
        remote_follow_overrides={%{}}
        user_statuses={@user_statuses}
        lemmy_counts={%{}}
        post_interactions={%{}}
        post_reactions_map={@post_reactions}
        post_replies={%{}}
        reactions={Map.get(@post_reactions, @post.id, [])}
        resolve_reply_refs={true}
        show_thread_context={false}
        show_ancestor_actions={true}
        on_image_click="open_image_modal"
        source="overview"
      />
    </div>
    """
  end
end
