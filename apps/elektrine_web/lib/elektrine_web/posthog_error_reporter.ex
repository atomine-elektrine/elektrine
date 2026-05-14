defmodule ElektrineWeb.PostHogErrorReporter do
  @moduledoc false

  @handler_id {__MODULE__, :phoenix_error_rendered}
  @event [:phoenix, :error_rendered]

  def attach do
    case :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  def handle_event(_event, _measurements, metadata, _config) do
    with %{} = log_event <- log_event(metadata), %{} = config <- posthog_config() do
      PostHog.Handler.log(log_event, %{config: config})
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc false
  def log_event(%{
        status: status,
        kind: kind,
        reason: reason,
        stacktrace: [_ | _] = stacktrace,
        conn: %Plug.Conn{} = conn
      })
      when is_integer(status) and status >= 500 do
    %{
      level: :error,
      meta:
        conn
        |> logger_metadata()
        |> Map.merge(%{
          crash_reason: crash_reason(kind, reason, stacktrace),
          posthog_source: :phoenix_error_rendered
        })
        |> Map.merge(conn_metadata(conn)),
      msg:
        {:report,
         %{
           label: {:phoenix, :error_rendered},
           message: Exception.format(kind, reason, stacktrace)
         }}
    }
  end

  def log_event(_metadata), do: nil

  defp logger_metadata(conn) do
    Logger.metadata()
    |> Map.new()
    |> Map.take([:request_id, :user_id, :distinct_id])
    |> put_current_user(conn)
  end

  defp put_current_user(metadata, %{assigns: %{current_user: %{id: user_id}}}) do
    metadata
    |> Map.put(:user_id, user_id)
    |> Map.put(:distinct_id, to_string(user_id))
  end

  defp put_current_user(metadata, _conn), do: metadata

  defp crash_reason(:throw, reason, stacktrace), do: {{:nocatch, reason}, stacktrace}
  defp crash_reason(:exit, reason, stacktrace), do: {reason, stacktrace}

  defp crash_reason(kind, reason, stacktrace),
    do: {Exception.normalize(kind, reason, stacktrace), stacktrace}

  defp conn_metadata(conn) do
    %{
      method: conn.method,
      path: conn.request_path,
      user_agent: conn |> Plug.Conn.get_req_header("user-agent") |> List.first(),
      remote_ip: format_remote_ip(conn.remote_ip)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp format_remote_ip(nil), do: nil
  defp format_remote_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp format_remote_ip(ip), do: to_string(ip)

  defp posthog_config do
    with true <- posthog_error_tracking_enabled?(),
         pid when is_pid(pid) <- Process.whereis(PostHog.Registry) do
      PostHog.config()
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp posthog_error_tracking_enabled? do
    Application.get_env(:posthog, :enable, true) == true and
      Application.get_env(:posthog, :enable_error_tracking, true) == true
  end
end
