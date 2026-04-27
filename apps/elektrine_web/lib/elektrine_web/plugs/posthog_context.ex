defmodule ElektrineWeb.Plugs.PostHogContext do
  @moduledoc false

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %{id: user_id} -> PostHog.set_context(%{distinct_id: to_string(user_id)})
      _ -> :ok
    end

    conn
  end
end
