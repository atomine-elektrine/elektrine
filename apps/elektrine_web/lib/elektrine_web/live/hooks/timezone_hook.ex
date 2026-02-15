defmodule ElektrineWeb.Live.Hooks.TimezoneHook do
  @moduledoc """
  LiveView hook to provide user's timezone and time format to all LiveViews.
  Uses user's saved preferences if available.
  For auto-detect (nil timezone), uses browser-detected timezone from session or defaults to UTC.
  """
  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    # Get timezone and time format from current user if authenticated
    {timezone, time_format} =
      case socket.assigns[:current_user] do
        # User has explicit timezone preference
        %{timezone: tz, time_format: tf} when is_binary(tz) and is_binary(tf) ->
          {tz, tf}

        %{timezone: tz} when is_binary(tz) ->
          {tz, "12"}

        # User has auto-detect (nil timezone) - check session for detected timezone
        %{timezone: nil, time_format: tf} when is_binary(tf) ->
          detected = session["detected_timezone"] || "Etc/UTC"
          {detected, tf}

        %{timezone: nil} ->
          detected = session["detected_timezone"] || "Etc/UTC"
          {detected, "12"}

        # No user preferences at all
        %{time_format: tf} when is_binary(tf) ->
          {"Etc/UTC", tf}

        _ ->
          {"Etc/UTC", "12"}
      end

    socket =
      socket
      |> assign(:timezone, timezone)
      |> assign(:time_format, time_format)

    {:cont, socket}
  end
end
