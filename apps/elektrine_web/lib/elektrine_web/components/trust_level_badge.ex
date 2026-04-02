defmodule ElektrineWeb.Components.TrustLevelBadge do
  @moduledoc """
  Trust level badge component for displaying user trust levels.
  """
  defdelegate trust_level_badge(assigns), to: Elektrine.Components.TrustLevelBadge
end
