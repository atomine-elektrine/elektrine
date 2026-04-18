defmodule ElektrineSocialWeb.TimelineLive.Operations.TrackingOperations do
  @moduledoc """
  Handles user engagement tracking events for the timeline live view.
  This includes dwell time tracking, dismissals, and session context updates
  for the recommendation system.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Elektrine.Social.Recommendations
  alias ElektrineSocialWeb.TimelineLive.Operations.Helpers

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

  def handle_event("restore_session_continuity", params, socket) do
    last_timeline_visit_at = parse_unix_ms_datetime(params["last_timeline_visit_at"])

    community_last_visited_at =
      params["community_last_visited_at"]
      |> normalize_community_last_visited_at()

    updated_socket =
      socket
      |> assign(:last_timeline_visit_at, last_timeline_visit_at)
      |> assign(:community_last_visited_at, community_last_visited_at)

    {:noreply, ElektrineSocialWeb.TimelineLive.Index.assign_continuity_state(updated_socket)}
  end

  # Marks a post as "not interested" - a strong negative signal.
  # This will reduce similar content in future recommendations.
  def handle_event("not_interested", params, socket) do
    user = socket.assigns[:current_user]

    updated_socket =
      if user do
        case params["post_id"] do
          nil ->
            socket

          post_id ->
            Recommendations.record_dismissal(user.id, post_id, "not_interested", nil)

            socket
            |> Helpers.remove_post_from_socket(post_id)
            |> put_flash(:info, "We’ll show less like this.")
        end
      else
        socket
      end

    {:noreply, updated_socket}
  end

  # Hides a post from the user's timeline.
  def handle_event("hide_post", params, socket) do
    user = socket.assigns[:current_user]

    updated_socket =
      if user do
        case params["post_id"] do
          nil ->
            socket

          post_id ->
            Recommendations.record_dismissal(user.id, post_id, "hidden", nil)

            socket
            |> Helpers.remove_post_from_socket(post_id)
            |> put_flash(:info, "Post hidden from your timeline.")
        end
      else
        socket
      end

    {:noreply, updated_socket}
  end

  defp normalize_community_last_visited_at(last_visited_at) when is_map(last_visited_at) do
    Enum.reduce(last_visited_at, %{}, fn {community_id, timestamp}, acc ->
      case parse_unix_ms_datetime(timestamp) do
        %DateTime{} = visited_at -> Map.put(acc, to_string(community_id), visited_at)
        _ -> acc
      end
    end)
  end

  defp normalize_community_last_visited_at(_last_visited_at), do: %{}

  defp parse_unix_ms_datetime(value) when is_integer(value) do
    DateTime.from_unix!(value, :millisecond)
  rescue
    _ -> nil
  end

  defp parse_unix_ms_datetime(value) when is_binary(value) do
    case Integer.parse(value) do
      {int_value, ""} -> parse_unix_ms_datetime(int_value)
      _ -> nil
    end
  end

  defp parse_unix_ms_datetime(_value), do: nil
end
