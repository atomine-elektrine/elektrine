defmodule ElektrineWeb.Components.Social.RemotePostShared do
  @moduledoc """
  Compatibility wrapper for the social app remote post shared rendering primitives.
  """

  alias ElektrineWeb.OptionalModule

  @component_module :"Elixir.ElektrineSocialWeb.Components.Social.RemotePostShared"

  def quote_preview(assigns) do
    OptionalModule.call(:social, @component_module, :quote_preview, [assigns], "")
  end

  def media_gallery(assigns) do
    OptionalModule.call(:social, @component_module, :media_gallery, [assigns], "")
  end

  def inline_reply_form(assigns) do
    OptionalModule.call(:social, @component_module, :inline_reply_form, [assigns], "")
  end
end
