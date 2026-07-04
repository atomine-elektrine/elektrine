defmodule ElektrineWeb.MessagingFederationRateLimitTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Federation.IngressRateLimiter

  @secret "rate-limit-shared-secret"

  setup do
    previous = Application.get_env(:elektrine, :messaging_federation)
    domain = "rl-#{System.unique_integer([:positive])}.test"

    on_exit(fn ->
      Application.put_env(:elektrine, :messaging_federation, previous)
    end)

    IngressRateLimiter.reset()

    # Requests in one test must land in the same fixed window; wait out the
    # rare case where a test starts right before a minute boundary.
    seconds_left = 60 - rem(System.system_time(:second), 60)
    if seconds_left < 3, do: Process.sleep(seconds_left * 1000 + 50)

    {:ok, domain: domain}
  end

  defp configure_federation(domain, limit_overrides) do
    Application.put_env(
      :elektrine,
      :messaging_federation,
      [
        enabled: true,
        identity_key_id: "k1",
        peers: [
          %{
            "domain" => domain,
            "base_url" => "https://#{domain}",
            "shared_secret" => @secret,
            "allow_incoming" => true,
            "allow_outgoing" => true
          }
        ]
      ] ++ limit_overrides
    )
  end

  defp signed_federation_headers(conn, domain, method, path, opts) do
    timestamp = Integer.to_string(System.system_time(:second))
    raw_body = Keyword.get(opts, :raw_body, "")
    query_string = Keyword.get(opts, :query_string, "")
    request_id = Ecto.UUID.generate()
    content_digest = Federation.body_digest(raw_body)

    signature =
      Federation.sign_payload(
        Federation.signature_payload(
          domain,
          method,
          path,
          query_string,
          timestamp,
          content_digest,
          request_id
        ),
        @secret
      )

    conn
    |> put_req_header("x-arblarg-domain", domain)
    |> put_req_header("x-arblarg-key-id", "k1")
    |> put_req_header("x-arblarg-timestamp", timestamp)
    |> put_req_header("x-arblarg-content-digest", content_digest)
    |> put_req_header("x-arblarg-request-id", request_id)
    |> put_req_header("x-arblarg-signature-algorithm", "ed25519")
    |> put_req_header("x-arblarg-signature", signature)
  end

  defp post_signed(domain, path, payload) do
    body = Jason.encode!(payload)

    build_conn()
    |> signed_federation_headers(domain, "POST", path, raw_body: body)
    |> put_req_header("content-type", "application/json")
    |> post(path, body)
  end

  defp get_signed(domain, path, query_string) do
    build_conn()
    |> signed_federation_headers(domain, "GET", path, query_string: query_string)
    |> get("#{path}?#{query_string}")
  end

  defp assert_rate_limited(conn) do
    response = json_response(conn, 429)
    assert response["code"] == "rate_limited"
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) in 1..60
  end

  test "durable events over the per-peer limit return 429 rate_limited", %{domain: domain} do
    configure_federation(domain, ingress_peer_durable_events_per_minute: 2)

    payload = %{"stream_id" => "stream:one"}

    for _ <- 1..2 do
      conn = post_signed(domain, "/_arblarg/events", payload)
      refute conn.status == 429
    end

    assert_rate_limited(post_signed(domain, "/_arblarg/events", payload))
  end

  test "per-room limit rejects a hot stream while other streams still pass", %{domain: domain} do
    configure_federation(domain,
      ingress_peer_durable_events_per_minute: 100,
      ingress_room_durable_events_per_minute: 1
    )

    refute post_signed(domain, "/_arblarg/events", %{"stream_id" => "stream:hot"}).status == 429

    assert_rate_limited(post_signed(domain, "/_arblarg/events", %{"stream_id" => "stream:hot"}))

    refute post_signed(domain, "/_arblarg/events", %{"stream_id" => "stream:cold"}).status == 429
  end

  test "a batch exceeding remaining capacity is rejected up front", %{domain: domain} do
    configure_federation(domain, ingress_peer_durable_events_per_minute: 3)

    events = Enum.map(1..4, fn index -> %{"stream_id" => "stream:#{index}"} end)

    assert_rate_limited(
      post_signed(domain, "/_arblarg/events/batch", %{"batch_id" => "b1", "events" => events})
    )

    # The rejected batch consumed no budget; a batch within capacity proceeds.
    smaller = Enum.take(events, 3)

    conn =
      post_signed(domain, "/_arblarg/events/batch", %{"batch_id" => "b2", "events" => smaller})

    refute conn.status == 429
  end

  test "ephemeral items over the per-peer limit return 429", %{domain: domain} do
    configure_federation(domain, ingress_peer_ephemeral_items_per_minute: 2)

    items = Enum.map(1..3, fn _ -> %{"event_type" => "typing.start"} end)

    assert_rate_limited(
      post_signed(domain, "/_arblarg/ephemeral", %{"batch_id" => "e1", "items" => items})
    )
  end

  test "sync and snapshot share the sync lane limit", %{domain: domain} do
    configure_federation(domain, ingress_peer_sync_requests_per_minute: 1)

    refute post_signed(domain, "/_arblarg/sync", %{"version" => 1}).status == 429

    conn =
      build_conn()
      |> signed_federation_headers(domain, "GET", "/_arblarg/servers/1/snapshot", [])
      |> get("/_arblarg/servers/1/snapshot")

    assert_rate_limited(conn)
  end

  test "replay requests over the limit return 429", %{domain: domain} do
    configure_federation(domain, ingress_peer_replay_requests_per_minute: 1)

    query_string = URI.encode_query(%{"stream_id" => "stream:replay"})

    refute get_signed(domain, "/_arblarg/streams/events", query_string).status == 429
    assert_rate_limited(get_signed(domain, "/_arblarg/streams/events", query_string))
  end

  test "exempted peer domains bypass ingress rate limits", %{domain: domain} do
    configure_federation(domain,
      ingress_peer_durable_events_per_minute: 1,
      ingress_rate_limit_exempt_domains: [domain]
    )

    for _ <- 1..3 do
      conn = post_signed(domain, "/_arblarg/events", %{"stream_id" => "stream:one"})
      refute conn.status == 429
    end
  end

  test "discovery endpoints are not rate limited", %{domain: domain} do
    configure_federation(domain, ingress_peer_sync_requests_per_minute: 1)

    for _ <- 1..5 do
      conn = get(build_conn(), "/.well-known/_arblarg")
      assert conn.status == 200
    end
  end
end
