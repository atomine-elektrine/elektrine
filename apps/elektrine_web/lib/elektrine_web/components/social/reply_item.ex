defmodule ElektrineWeb.Components.Social.ReplyItem do
  @moduledoc """
  Compatibility wrapper for the social app reply item component.
  """

  def reply_item(assigns) do
    ElektrineSocialWeb.Components.Social.ReplyItem.reply_item(assigns)
  end

  def normalize_reply(reply) do
    ElektrineSocialWeb.Components.Social.ReplyItem.normalize_reply(reply)
  end
end
