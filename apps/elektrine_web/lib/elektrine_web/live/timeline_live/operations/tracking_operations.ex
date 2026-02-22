defmodule ElektrineWeb.TimelineLive.Operations.TrackingOperations do
  @moduledoc """
  Handles user engagement tracking events for the timeline live view.
  This includes dwell time tracking, dismissals, and session context updates
  for the recommendation system.
  """

  import Phoenix.Component

  alias Elektrine.Social.Recommendations

  # Records dwell time for a single post view.
  # Called when a post leaves the viewport or on component destruction.
  def handle_event("record_dwell_time", params, socket) do
    user = socket.assigns[:current_user]

    if user do
      post_id = params["post_id"]

      if post_id do
        attrs = %{
          dwell_time_ms: params["dwell_time_ms"],
          scroll_depth: params["scroll_depth"],
          expanded: params["expanded"] || false,
          source: params["source"] || "timeline"
        }

        Recommendations.record_view_with_dwell(user.id, post_id, attrs)
      end
    end

    {:noreply, socket}
  end

  # Records dwell times for multiple posts in a batch.
  # Called periodically (every 5 seconds) to batch dwell time updates.
  def handle_event("record_dwell_times", %{"views" => views}, socket) do
    user = socket.assigns[:current_user]

    if user do
      Enum.each(views, fn view ->
        post_id = view["post_id"]

        if post_id do
          attrs = %{
            dwell_time_ms: view["dwell_time_ms"],
            scroll_depth: view["scroll_depth"],
            expanded: view["expanded"] || false,
            source: view["source"] || "timeline"
          }

          Recommendations.record_view_with_dwell(user.id, post_id, attrs)
        end
      end)
    end

    {:noreply, socket}
  end

  # Records a post dismissal signal (scrolled past, hidden, not interested).
  # These are negative signals used to improve recommendations.
  def handle_event("record_dismissal", params, socket) do
    user = socket.assigns[:current_user]

    if user do
      post_id = params["post_id"]
      type = params["type"]
      dwell_time_ms = params["dwell_time_ms"]

      if post_id && type do
        Recommendations.record_dismissal(user.id, post_id, type, dwell_time_ms)
      end
    end

    {:noreply, socket}
  end

  # Updates session context for real-time recommendation adaptation.
  # Stores engagement patterns from the current session.
  def handle_event("update_session_context", params, socket) do
    # Store session context in socket assigns for use in next feed refresh
    liked_creators = params["liked_creators"] || []
    liked_local_creators = params["liked_local_creators"] || liked_creators

    session_context = %{
      liked_hashtags: params["liked_hashtags"] || [],
      liked_creators: liked_creators,
      liked_local_creators: liked_local_creators,
      liked_remote_creators: params["liked_remote_creators"] || [],
      viewed_posts: params["viewed_posts"] || [],
      engagement_rate: params["engagement_rate"] || 0.0
    }

    {:noreply, assign(socket, :session_context, session_context)}
  end

  # Marks a post as "not interested" - a strong negative signal.
  # This will reduce similar content in future recommendations.
  def handle_event("not_interested", params, socket) do
    user = socket.assigns[:current_user]

    if user do
      post_id = params["post_id"]

      if post_id do
        Recommendations.record_dismissal(user.id, post_id, "not_interested", nil)
      end
    end

    {:noreply, socket}
  end

  # Hides a post from the user's timeline.
  def handle_event("hide_post", params, socket) do
    user = socket.assigns[:current_user]

    if user do
      post_id = params["post_id"]

      if post_id do
        Recommendations.record_dismissal(user.id, post_id, "hidden", nil)
      end
    end

    {:noreply, socket}
  end
end
