defmodule ElektrineWeb.Plugs.ConditionalLiveReloader do
  @moduledoc false

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["email", _id, "iframe_content"]} = conn, _opts), do: conn

  def call(conn, opts), do: Phoenix.LiveReloader.call(conn, opts)
end
