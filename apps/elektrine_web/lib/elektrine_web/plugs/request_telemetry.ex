defmodule ElektrineWeb.Plugs.RequestTelemetry do
  @moduledoc """
  Emits business request telemetry for API and DAV pipelines.
  """

  import Plug.Conn

  alias Elektrine.Telemetry.Events

  def init(opts), do: opts

  def call(conn, opts) do
    scope = Keyword.fetch!(opts, :scope)
    started_at = System.monotonic_time(:millisecond)
    endpoint_group = endpoint_group(conn.request_path)

    register_before_send(conn, fn conn ->
      duration = System.monotonic_time(:millisecond) - started_at

      metadata = %{
        method: conn.method,
        endpoint_group: endpoint_group
      }

      case scope do
        :api -> Events.api_request(duration, conn.status || 0, metadata)
        :dav -> Events.dav_request(duration, conn.status || 0, metadata)
        _ -> :ok
      end

      conn
    end)
  end

  defp endpoint_group(path) when is_binary(path) do
    segments =
      path
      |> String.trim("/")
      |> String.split("/", trim: true)

    case segments do
      [first, second | _] -> "#{first}/#{second}"
      [first] -> first
      _ -> "root"
    end
  end

  defp endpoint_group(_), do: "unknown"
end
