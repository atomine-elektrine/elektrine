defmodule Elektrine.Uptime.CheckerTest do
  use ExUnit.Case, async: false

  alias Elektrine.Uptime.Checker
  alias Elektrine.Uptime.Monitor

  setup do
    on_exit(fn ->
      Application.delete_env(:elektrine_uptime, :http_fun)
      Application.delete_env(:elektrine_uptime, :tcp_connect_fun)
      Application.delete_env(:elektrine_uptime, :ping_fun)
    end)

    :ok
  end

  defp http_monitor(attrs \\ %{}) do
    Map.merge(
      %Monitor{
        check_type: "http",
        target: "https://example.com",
        expected_status: 200,
        keyword: nil,
        timeout_ms: 5_000
      },
      attrs
    )
  end

  defp tcp_monitor(attrs \\ %{}) do
    Map.merge(
      %Monitor{check_type: "tcp", target: "example.com", port: 443, timeout_ms: 5_000},
      attrs
    )
  end

  defp ping_monitor(attrs \\ %{}) do
    Map.merge(%Monitor{check_type: "ping", target: "example.com", timeout_ms: 5_000}, attrs)
  end

  defp stub_http(fun), do: Application.put_env(:elektrine_uptime, :http_fun, fun)
  defp stub_tcp(fun), do: Application.put_env(:elektrine_uptime, :tcp_connect_fun, fun)
  defp stub_ping(fun), do: Application.put_env(:elektrine_uptime, :ping_fun, fun)

  describe "http" do
    test "up when status matches and keyword present" do
      stub_http(fn _req, _finch, _opts ->
        {:ok, %Finch.Response{status: 200, headers: [], body: "hello world"}}
      end)

      assert {:up, %{response_time_ms: rt, status_code: 200}} =
               Checker.run(http_monitor(%{keyword: "world"}))

      assert is_integer(rt) and rt >= 0
    end

    test "up against 2xx when expected_status is nil" do
      stub_http(fn _req, _finch, _opts ->
        {:ok, %Finch.Response{status: 204, headers: [], body: ""}}
      end)

      assert {:up, %{status_code: 204}} = Checker.run(http_monitor(%{expected_status: nil}))
    end

    test "down on status mismatch" do
      stub_http(fn _req, _finch, _opts ->
        {:ok, %Finch.Response{status: 500, headers: [], body: ""}}
      end)

      assert {:down, reason} = Checker.run(http_monitor())
      assert reason =~ "500"
    end

    test "down when keyword missing" do
      stub_http(fn _req, _finch, _opts ->
        {:ok, %Finch.Response{status: 200, headers: [], body: "nope"}}
      end)

      assert {:down, "keyword not found"} = Checker.run(http_monitor(%{keyword: "present"}))
    end

    test "down on transport timeout" do
      stub_http(fn _req, _finch, _opts -> {:error, :timeout} end)

      assert {:down, reason} = Checker.run(http_monitor())
      assert reason =~ "timeout"
    end

    test "SSRF guard rejects private http target without a network call" do
      stub_http(fn _req, _finch, _opts ->
        flunk("transport should not be reached for a blocked target")
      end)

      assert {:down, reason} = Checker.run(http_monitor(%{target: "http://127.0.0.1"}))
      assert reason =~ "blocked"
    end
  end

  describe "tcp" do
    test "up on successful connect" do
      stub_tcp(fn _ip, _port, _opts, _timeout -> {:ok, :fake_socket} end)
      assert {:up, %{status_code: nil}} = Checker.run(tcp_monitor())
    end

    test "down on econnrefused" do
      stub_tcp(fn _ip, _port, _opts, _timeout -> {:error, :econnrefused} end)

      assert {:down, reason} = Checker.run(tcp_monitor())
      assert reason =~ "tcp" and reason =~ "econnrefused"
    end

    test "down on timeout" do
      stub_tcp(fn _ip, _port, _opts, _timeout -> {:error, :timeout} end)
      assert {:down, reason} = Checker.run(tcp_monitor())
      assert reason =~ "timeout"
    end

    test "SSRF guard rejects a private TCP host without connecting" do
      stub_tcp(fn _ip, _port, _opts, _timeout ->
        flunk("transport should not be reached for a private host")
      end)

      assert {:down, reason} = Checker.run(tcp_monitor(%{target: "127.0.0.1"}))
      assert reason =~ "tcp"
    end

    test "rejects a dangerous port" do
      stub_tcp(fn _ip, _port, _opts, _timeout ->
        flunk("transport should not be reached for a dangerous port")
      end)

      assert {:down, reason} = Checker.run(tcp_monitor(%{port: 22}))
      assert reason =~ "dangerous_port"
    end
  end

  describe "ping" do
    test "up on exit 0 and parses rtt" do
      stub_ping(fn _host, _t -> {"64 bytes: time=12.3 ms", 0} end)
      assert {:up, %{response_time_ms: 12, status_code: nil}} = Checker.run(ping_monitor())
    end

    test "down on non-zero exit" do
      stub_ping(fn _host, _t -> {"100% packet loss", 1} end)
      assert {:down, reason} = Checker.run(ping_monitor())
      assert reason =~ "exit 1"
    end

    test "SSRF guard rejects a private ping host" do
      stub_ping(fn _host, _t -> flunk("ping should not run for a private host") end)
      assert {:down, _reason} = Checker.run(ping_monitor(%{target: "127.0.0.1"}))
    end
  end
end
