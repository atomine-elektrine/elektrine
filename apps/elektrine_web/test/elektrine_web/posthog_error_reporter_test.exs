defmodule ElektrineWeb.PostHogErrorReporterTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ElektrineWeb.PostHogErrorReporter

  setup do
    Logger.metadata(request_id: nil)

    :ok
  end

  test "builds a PostHog logger event with Phoenix exception stacktrace metadata" do
    reason = %RuntimeError{message: "boom"}
    stacktrace = stacktrace()

    Logger.metadata(request_id: "request-123")

    conn =
      :get
      |> conn("/boom")
      |> Plug.Conn.put_req_header("user-agent", "test-agent")
      |> Map.put(:remote_ip, {203, 0, 113, 7})
      |> Plug.Conn.assign(:current_user, %{id: 42})

    assert %{
             level: :error,
             meta: meta,
             msg: {:report, %{label: {:phoenix, :error_rendered}, message: message}}
           } =
             PostHogErrorReporter.log_event(%{
               status: 500,
               kind: :error,
               reason: reason,
               stacktrace: stacktrace,
               conn: conn
             })

    refute Map.has_key?(meta, :conn)
    assert meta.crash_reason == {reason, stacktrace}
    assert meta.request_id == "request-123"
    assert meta.user_id == 42
    assert meta.distinct_id == "42"
    assert meta.method == "GET"
    assert meta.path == "/boom"
    assert meta.user_agent == "test-agent"
    assert meta.remote_ip == "203.0.113.7"
    assert meta.posthog_source == :phoenix_error_rendered
    assert message =~ "** (RuntimeError) boom"
  end

  test "preserves throw reasons in the shape PostHog's handler expects" do
    stacktrace = stacktrace()

    assert %{meta: %{crash_reason: {{:nocatch, :bad_request}, ^stacktrace}}} =
             PostHogErrorReporter.log_event(%{
               status: 500,
               kind: :throw,
               reason: :bad_request,
               stacktrace: stacktrace,
               conn: conn(:get, "/boom")
             })
  end

  test "ignores non-server responses and missing stacktraces" do
    reason = %RuntimeError{message: "boom"}
    stacktrace = stacktrace()
    conn = conn(:get, "/missing")

    assert is_nil(
             PostHogErrorReporter.log_event(%{
               status: 404,
               kind: :error,
               reason: reason,
               stacktrace: stacktrace,
               conn: conn
             })
           )

    assert is_nil(
             PostHogErrorReporter.log_event(%{
               status: 500,
               kind: :error,
               reason: reason,
               stacktrace: [],
               conn: conn
             })
           )
  end

  defp stacktrace do
    [{__MODULE__, :sample, 0, [file: ~c"posthog_error_reporter_test.exs", line: 1]}]
  end
end
