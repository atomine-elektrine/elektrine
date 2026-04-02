defmodule ElektrineWeb.Components.Loaders.Skeleton do
  @moduledoc false
  defdelegate post_skeleton(assigns), to: Elektrine.Components.Loaders.Skeleton
  defdelegate profile_skeleton(assigns), to: Elektrine.Components.Loaders.Skeleton
  defdelegate reply_skeleton(assigns), to: Elektrine.Components.Loaders.Skeleton
  defdelegate user_card_skeleton(assigns), to: Elektrine.Components.Loaders.Skeleton
  defdelegate discussion_skeleton(assigns), to: Elektrine.Components.Loaders.Skeleton
  defdelegate community_skeleton(assigns), to: Elektrine.Components.Loaders.Skeleton
  defdelegate gallery_skeleton(assigns), to: Elektrine.Components.Loaders.Skeleton
  defdelegate timeline_skeleton(assigns), to: Elektrine.Components.Loaders.Skeleton
end
