defmodule ElektrineEmailWeb.EmailPreferenceHelpers do
  @moduledoc false

  def type_badge_class(:transactional), do: "badge-error"
  def type_badge_class(:marketing), do: "badge-primary"
  def type_badge_class(:notifications), do: "badge-info"

  def format_type(:transactional), do: "Transactional"
  def format_type(:marketing), do: "Marketing"
  def format_type(:notifications), do: "Notifications"
end
