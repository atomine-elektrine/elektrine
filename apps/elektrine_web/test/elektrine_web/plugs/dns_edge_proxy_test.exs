defmodule ElektrineWeb.Plugs.DNSEdgeProxyTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias ElektrineWeb.AtomineGate
  alias ElektrineWeb.Plugs.DNSEdgeProxy

  defmodule OriginResolverStub do
    def proxied_origin_for_host("proxied.test") do
      {:ok,
       %{
         zone_id: 1,
         record_id: 2,
         host: "proxied.test",
         origin_url: "https://origin.example.net:8443",
         origin_host_header: "proxied.test",
         atomine_gate: false
       }}
    end

    def proxied_origin_for_host("gated.test") do
      {:ok,
       %{
         zone_id: 1,
         record_id: 3,
         host: "gated.test",
         origin_url: "https://origin.example.net:8443",
         origin_host_header: "gated.test",
         atomine_gate: true
       }}
    end

    def proxied_origin_for_host(_host), do: {:error, :not_found}
  end

  defmodule HTTPClientStub do
    def request(request, opts) do
      Process.put(:dns_edge_proxy_request, {request, opts})

      {:ok,
       %Finch.Response{
         status: 202,
         headers: [
           {"content-type", "text/plain"},
           {"transfer-encoding", "chunked"},
           {"x-origin", "ok"}
         ],
         body: "proxied"
       }}
    end
  end

  setup do
    previous_dns_config = Application.get_env(:elektrine, :dns, [])
    previous_atomine_gate_config = Application.get_env(:elektrine, :atomine_gate, [])
    previous_atomine_pow_config = Application.get_env(:elektrine, :atomine_pow, [])

    Application.put_env(
      :elektrine,
      :dns,
      Keyword.merge(previous_dns_config,
        edge_proxy_enabled: true,
        edge_proxy_origin_resolver: {OriginResolverStub, :proxied_origin_for_host},
        edge_proxy_http_client: HTTPClientStub
      )
    )

    on_exit(fn ->
      Application.put_env(:elektrine, :dns, previous_dns_config)
      Application.put_env(:elektrine, :atomine_gate, previous_atomine_gate_config)
      Application.put_env(:elektrine, :atomine_pow, previous_atomine_pow_config)
      Process.delete(:dns_edge_proxy_request)
    end)
  end

  test "proxies verified DNS hosts to their origin" do
    conn =
      :post
      |> Plug.Test.conn("/submit?foo=bar", "payload")
      |> Map.put(:host, "proxied.test")
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("connection", "close")
      |> put_req_header("x-forwarded-proto", "https")
      |> DNSEdgeProxy.call([])

    assert conn.halted
    assert conn.status == 202
    assert conn.resp_body == "proxied"
    assert get_resp_header(conn, "content-type") == ["text/plain"]
    assert get_resp_header(conn, "x-origin") == ["ok"]
    assert get_resp_header(conn, "transfer-encoding") == []

    assert {%Finch.Request{} = request, opts} = Process.get(:dns_edge_proxy_request)
    assert request.method == "POST"
    assert request.scheme == :https
    assert request.host == "origin.example.net"
    assert request.port == 8443
    assert request.path == "/submit"
    assert request.query == "foo=bar"
    assert request.body == "payload"

    headers = Map.new(request.headers)
    assert headers["host"] == "proxied.test"
    assert headers["x-forwarded-host"] == "proxied.test"
    assert headers["x-forwarded-proto"] == "https"
    assert headers["x-elektrine-edge-proxy"] == "1"
    refute Map.has_key?(headers, "connection")
    assert opts[:max_body_bytes] == 50 * 1024 * 1024
  end

  test "leaves non-proxied hosts untouched" do
    conn =
      :get
      |> Plug.Test.conn("/")
      |> Map.put(:host, "plain.test")
      |> DNSEdgeProxy.call([])

    refute conn.halted
    refute Process.get(:dns_edge_proxy_request)
  end

  test "does not proxy internal edge endpoints" do
    conn =
      :get
      |> Plug.Test.conn("/_edge/proxy/v1/origin")
      |> Map.put(:host, "proxied.test")
      |> DNSEdgeProxy.call([])

    refute conn.halted
    refute Process.get(:dns_edge_proxy_request)
  end

  test "shows Security Check splash before proxying gated origins" do
    with_atomine_gate_enabled(fn ->
      conn =
        :get
        |> Plug.Test.conn("/protected")
        |> Map.put(:host, "gated.test")
        |> DNSEdgeProxy.call([])

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body =~ "Security Check"
      assert conn.resp_body =~ "Checking your browser"
      assert conn.resp_body =~ ~s(name="gate_scope" value="dns:1:3")
      refute Process.get(:dns_edge_proxy_request)
    end)
  end

  test "verification path is handled at the edge instead of proxied" do
    with_atomine_gate_enabled(fn ->
      conn =
        Plug.Test.conn(:post, AtomineGate.verify_path(), %{
          "atomine_pow_token" => "test-token",
          "gate_scope" => "dns:1:3",
          "return_to" => "/protected"
        })
        |> Map.put(:host, "gated.test")
        |> DNSEdgeProxy.call([])

      assert conn.halted
      assert conn.status == 303
      assert get_resp_header(conn, "location") == ["/protected"]
      refute Process.get(:dns_edge_proxy_request)
    end)
  end

  defp with_atomine_gate_enabled(fun) do
    Application.put_env(:elektrine, :atomine_gate,
      enabled: true,
      difficulty: 1,
      clearance_ttl_seconds: 60
    )

    Application.put_env(:elektrine, :atomine_pow,
      difficulty: 1,
      skip_verification: true
    )

    fun.()
  end
end
