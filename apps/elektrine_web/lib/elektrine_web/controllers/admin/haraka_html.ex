defmodule ElektrineWeb.Admin.HarakaHTML do
  @moduledoc false

  use ElektrineWeb, :html

  embed_templates "haraka_html/*"

  def haraka_status_badge_class(:connected), do: "bg-success/15 text-success"
  def haraka_status_badge_class(:error), do: "bg-warning/20 text-warning-content"
  def haraka_status_badge_class(_), do: "bg-base-200 text-base-content/70"

  def haraka_status_label(:connected), do: "Reachable"
  def haraka_status_label(:error), do: "Needs Attention"
  def haraka_status_label(_), do: "Unknown"

  def domain_status_badge_class(:ok), do: "badge-success"
  def domain_status_badge_class(:error), do: "badge-warning"
  def domain_status_badge_class(_), do: "badge-ghost"

  def domain_status_label(:ok), do: "Loaded"
  def domain_status_label(:error), do: "Unavailable"
  def domain_status_label(_), do: "Unknown"

  def format_metric(nil), do: "-"
  def format_metric(value) when is_integer(value), do: Integer.to_string(value)
  def format_metric(value), do: to_string(value)

  def format_uptime(nil), do: "Unknown"

  def format_uptime(seconds) when is_integer(seconds) and seconds >= 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m #{secs}s"
      minutes > 0 -> "#{minutes}m #{secs}s"
      true -> "#{secs}s"
    end
  end

  def format_uptime(_), do: "Unknown"
end
