defmodule ElektrineWeb.Components.Datetime.LocalTime do
  @moduledoc """
  Component for rendering datetime values in the user's timezone.
  """
  use Phoenix.Component

  @doc """
  Renders a timestamp in the user's local timezone using JavaScript.

  The datetime is converted from UTC to the user's browser timezone automatically.

  ## Examples

      <.local_time datetime={user.inserted_at} />
      <.local_time datetime={message.sent_at} format="relative" />
      <.local_time datetime={post.created_at} format="date" class="text-sm" />

  ## Formats

    * `datetime` (default) - "Jan 1, 2024, 10:30 AM"
    * `datetime-long` - "January 1, 2024, 10:30:45 AM"
    * `date` - "Jan 1, 2024"
    * `time` - "10:30 AM"
    * `relative` - "5m ago", "2h ago", "3d ago"
  """
  attr :datetime, :any, required: true
  attr :format, :string, default: "datetime"
  attr :class, :string, default: nil
  attr :timezone, :string, default: "Etc/UTC"
  attr :time_format, :string, default: "12"

  def local_time(assigns) do
    # Use provided timezone and time format or fallback to defaults
    timezone = assigns.timezone
    time_format = assigns.time_format

    # Format the datetime in the user's timezone on the server
    formatted = format_in_timezone(assigns.datetime, assigns.format, timezone, time_format)
    title = format_datetime_title(assigns.datetime, timezone, time_format)

    assigns = assign(assigns, :formatted, formatted)
    assigns = assign(assigns, :title, title)

    ~H"""
    <span :if={@formatted} class={@class} title={@title}>
      {@formatted}
    </span>
    """
  end

  # Format datetime in user's timezone
  defp format_in_timezone(nil, _format, _timezone, _time_format), do: nil

  defp format_in_timezone(datetime, format, timezone, time_format) do
    dt = ensure_datetime(datetime)
    if dt == nil, do: nil, else: format_datetime(dt, format, timezone, time_format)
  end

  # Convert various datetime types to DateTime
  defp ensure_datetime(%DateTime{} = dt), do: dt

  defp ensure_datetime(%NaiveDateTime{} = ndt) do
    DateTime.from_naive!(ndt, "Etc/UTC")
  end

  defp ensure_datetime(_), do: nil

  # Format datetime according to format and timezone
  defp format_datetime(datetime, "relative", _timezone, _time_format) do
    time_ago_simple(datetime)
  end

  defp format_datetime(datetime, format, timezone, time_format) do
    # Shift to user's timezone, fallback to UTC if timezone is invalid
    shifted =
      case DateTime.shift_zone(datetime, timezone, Tzdata.TimeZoneDatabase) do
        {:ok, dt} -> dt
        # Fallback to original UTC time
        {:error, _} -> datetime
      end

    # Choose time format based on user preference
    {time_str, datetime_str, datetime_long_str} =
      case time_format do
        "24" ->
          {"%H:%M", "%b %d, %Y %H:%M", "%B %d, %Y %H:%M:%S"}

        _ ->
          # Default to 12-hour format
          {"%I:%M %p", "%b %d, %Y %I:%M %p", "%B %d, %Y %I:%M:%S %p"}
      end

    case format do
      "date" ->
        Calendar.strftime(shifted, "%b %d, %Y")

      "datetime" ->
        Calendar.strftime(shifted, datetime_str)

      "datetime-long" ->
        Calendar.strftime(shifted, datetime_long_str)

      "time" ->
        Calendar.strftime(shifted, time_str)

      _ ->
        Calendar.strftime(shifted, datetime_str)
    end
  end

  defp format_datetime_title(nil, _timezone, _time_format), do: nil

  defp format_datetime_title(datetime, timezone, time_format) do
    dt = ensure_datetime(datetime)

    if dt do
      # Choose time format for title
      title_format =
        case time_format do
          "24" -> "%B %d, %Y %H:%M:%S"
          _ -> "%B %d, %Y %I:%M:%S %p"
        end

      case DateTime.shift_zone(dt, timezone, Tzdata.TimeZoneDatabase) do
        {:ok, shifted} ->
          tz_abbr = Map.get(shifted, :zone_abbr, "")
          "#{Calendar.strftime(shifted, title_format)} #{tz_abbr}"

        {:error, _} ->
          # Fallback to UTC
          "#{Calendar.strftime(dt, title_format)} UTC"
      end
    else
      nil
    end
  end

  defp time_ago_simple(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
  end
end
