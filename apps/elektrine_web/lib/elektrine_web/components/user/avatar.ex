defmodule ElektrineWeb.Components.User.Avatar do
  @moduledoc """
  Compatibility wrapper for shared avatar components.
  """

  defdelegate placeholder_avatar(assigns), to: Elektrine.Components.User.Avatar
  defdelegate user_avatar(assigns), to: Elektrine.Components.User.Avatar
  defdelegate conversation_avatar(assigns), to: Elektrine.Components.User.Avatar
end
