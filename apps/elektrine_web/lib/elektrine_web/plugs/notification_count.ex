defmodule ElektrineWeb.Plugs.NotificationCount do
  @moduledoc """
  Plug to load the notification count for the current user.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil ->
        conn

      user ->
        count = Elektrine.Notifications.get_unread_count(user.id)
        assign(conn, :notification_count, count)
    end
  end
end
