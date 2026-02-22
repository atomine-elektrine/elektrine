defmodule ElektrineWeb.Components.Presence.Helpers do
  @moduledoc """
  Helper functions for displaying presence information.
  """

  @doc """
  Formats a "last seen" timestamp into human-readable text.
  Returns nil if user is currently online/dnd.
  """
  def format_last_seen(status, last_seen_unix)
      when status == "offline" and is_integer(last_seen_unix) do
    now = System.system_time(:second)
    diff_seconds = now - last_seen_unix

    cond do
      diff_seconds < 60 ->
        "Last seen just now"

      diff_seconds < 3600 ->
        minutes = div(diff_seconds, 60)
        "Last seen #{minutes}m ago"

      diff_seconds < 86_400 ->
        hours = div(diff_seconds, 3600)
        "Last seen #{hours}h ago"

      diff_seconds < 604_800 ->
        days = div(diff_seconds, 86_400)
        "Last seen #{days}d ago"

      true ->
        "Last seen a while ago"
    end
  end

  def format_last_seen(_status, _last_seen), do: nil

  @doc """
  Gets status text with last seen info if offline.
  """
  def status_text("online", _last_seen), do: "Online"
  def status_text("away", _last_seen), do: "Away"
  def status_text("dnd", _last_seen), do: "Do Not Disturb"

  def status_text("offline", last_seen) when is_integer(last_seen) do
    format_last_seen("offline", last_seen) || "Offline"
  end

  def status_text("offline", _last_seen), do: "Offline"
  def status_text(_, _), do: "Online"
end
