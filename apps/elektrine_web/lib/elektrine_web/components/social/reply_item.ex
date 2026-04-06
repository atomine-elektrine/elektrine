defmodule ElektrineWeb.Components.Social.ReplyItem do
  @moduledoc """
  Compatibility wrapper for the social app reply item component.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.ReplyItem"

  def reply_item(assigns) do
    OptionalModule.call(:social, @component_module, :reply_item, [assigns], "")
  end

  def normalize_reply(reply) do
    OptionalModule.call(:social, @component_module, :normalize_reply, [reply], reply)
  end
end
