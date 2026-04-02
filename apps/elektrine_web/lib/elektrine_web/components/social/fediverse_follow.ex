defmodule ElektrineWeb.Components.Social.FediverseFollow do
  @moduledoc """
  Compatibility wrapper for the social app fediverse follow component.
  """

  def fediverse_follow(assigns) do
    ElektrineSocialWeb.Components.Social.FediverseFollow.fediverse_follow(assigns)
  end

  def actor_preview(assigns) do
    ElektrineSocialWeb.Components.Social.FediverseFollow.actor_preview(assigns)
  end

  def fediverse_follow_inline(assigns) do
    ElektrineSocialWeb.Components.Social.FediverseFollow.fediverse_follow_inline(assigns)
  end
end
