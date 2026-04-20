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
end
