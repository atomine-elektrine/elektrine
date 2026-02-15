defmodule ElektrineWeb.ProfileLive.Analytics do
  use ElektrineWeb, :live_view
  import ElektrineWeb.Components.User.Avatar
  alias Elektrine.Profiles

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    # Get comprehensive analytics
    stats = Profiles.get_profile_view_stats(user.id)
    recent_viewers = Profiles.get_recent_viewers(user.id, 20)
    top_referrers = Profiles.get_top_referrers(user.id, 10)
    top_links = Profiles.get_top_links(user.id, 10)
    viewer_breakdown = Profiles.get_viewer_breakdown(user.id)
    daily_views = Profiles.get_daily_view_counts(user.id, 30)

    timezone = user.timezone || "Etc/UTC"
    time_format = user.time_format || "12h"

    {:ok,
     socket
     |> assign(:page_title, "Profile Analytics")
     |> assign(:stats, stats)
     |> assign(:recent_viewers, recent_viewers)
     |> assign(:top_referrers, top_referrers)
     |> assign(:top_links, top_links)
     |> assign(:viewer_breakdown, viewer_breakdown)
     |> assign(:daily_views, daily_views)
     |> assign(:timezone, timezone)
     |> assign(:time_format, time_format)}
  end
end
