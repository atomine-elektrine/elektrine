defmodule ElektrineWeb.Components.Social.RemotePostShared do
  @moduledoc """
  Compatibility wrapper for the social app remote post shared rendering primitives.
  """

  def quote_preview(assigns) do
    ElektrineSocialWeb.Components.Social.RemotePostShared.quote_preview(assigns)
  end

  def media_gallery(assigns) do
    ElektrineSocialWeb.Components.Social.RemotePostShared.media_gallery(assigns)
  end

  def inline_reply_form(assigns) do
    ElektrineSocialWeb.Components.Social.RemotePostShared.inline_reply_form(assigns)
  end
end
