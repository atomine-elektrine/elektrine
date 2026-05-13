defmodule ElektrineWeb.Admin.EmailDeliveryHTML do
  @moduledoc false

  use ElektrineWeb, :html

  embed_templates "email_delivery_html/*"

  def format_percent(value) when is_float(value), do: "#{Float.round(value * 100, 2)}%"
  def format_percent(value) when is_integer(value), do: "#{value}%"
  def format_percent(_), do: "0.0%"

  def status_badge_class("sent"), do: "bg-success/15 text-success"
  def status_badge_class("pending"), do: "bg-info/15 text-info"
  def status_badge_class("sending"), do: "bg-info/15 text-info"
  def status_badge_class("deferred"), do: "bg-warning/20 text-warning-content"
  def status_badge_class("paused"), do: "bg-warning/20 text-warning-content"
  def status_badge_class("bounced"), do: "bg-error/15 text-error"
  def status_badge_class("complained"), do: "bg-error/15 text-error"
  def status_badge_class("failed"), do: "bg-error/15 text-error"
  def status_badge_class("suppressed"), do: "bg-base-200 text-base-content/70"
  def status_badge_class(_), do: "bg-base-200 text-base-content/70"
end
