defmodule ElektrineEmailWeb.Admin.HarakaControllerTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures

  defmodule MockHarakaHTTPClient do
    def request(method, url, headers, body, _opts) do
      request = %{method: method, url: url, headers: headers, body: body}
      Process.put({__MODULE__, :requests}, [request | requests()])

      case Process.get({__MODULE__, :responses}, []) do
        [response | rest] ->
          Process.put({__MODULE__, :responses}, rest)
          response

        [] ->
          {:ok,
           %Finch.Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "selector" => "default",
                 "public_key" => "-----BEGIN PUBLIC KEY-----\nABC123\n-----END PUBLIC KEY-----",
                 "private_key" => "present"
               })
           }}
      end
    end

    def put_responses(responses), do: Process.put({__MODULE__, :responses}, responses)
    def clear_responses, do: Process.put({__MODULE__, :responses}, [])
    def requests, do: Process.get({__MODULE__, :requests}, [])
    def clear_requests, do: Process.put({__MODULE__, :requests}, [])
  end

  setup do
    previous_email_config = Application.get_env(:elektrine, :email, [])

    Application.put_env(
      :elektrine,
      :email,
      Keyword.merge(
        previous_email_config,
        domain: "elektrine.test",
        supported_domains: ["elektrine.test", "z.org"],
        custom_domain_http_client: MockHarakaHTTPClient,
        custom_domain_haraka_base_url: "https://haraka.example.test",
        custom_domain_haraka_api_key: "haraka-http-key",
        custom_domain_mx_host: "mail.elektrine.test",
        custom_domain_mx_priority: 15,
        custom_domain_spf_include: "spf.elektrine.test",
        custom_domain_dmarc_rua: "dmarc@elektrine.test"
      )
    )

    MockHarakaHTTPClient.clear_requests()
    MockHarakaHTTPClient.clear_responses()

    on_exit(fn ->
      Application.put_env(:elektrine, :email, previous_email_config)
    end)

    :ok
  end

  describe "GET /pripyat/haraka" do
    test "renders Haraka connectivity and built-in domain DKIM records", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()

      MockHarakaHTTPClient.put_responses([
        {:ok,
         %Finch.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "data" => %{
                 "selector" => "default",
                 "public_key" => "-----BEGIN PUBLIC KEY-----\nABC123\n-----END PUBLIC KEY-----",
                 "private_key" => "configured"
               }
             })
         }},
        {:ok,
         %Finch.Response{
           status: 200,
           body:
             Jason.encode!(%{
               "selector" => "mailsel",
               "dkim_value" => "v=DKIM1; k=rsa; p=XYZ987"
             })
         }}
      ])

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/haraka")

      html = html_response(conn, 200)

      assert html =~ "Haraka"
      assert html =~ "https://haraka.example.test"
      assert html =~ "elektrine.test"
      assert html =~ "z.org"
      assert html =~ "mail.elektrine.test"
      assert html =~ "v=spf1 include:spf.elektrine.test ~all"
      assert html =~ "v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:dmarc@elektrine.test"
      assert html =~ "default._domainkey.elektrine.test"
      assert html =~ "mailsel._domainkey.z.org"
      assert html =~ "v=DKIM1; k=rsa; p=XYZ987"

      requests = Enum.reverse(MockHarakaHTTPClient.requests())
      assert Enum.map(requests, & &1.method) == [:get, :get]

      assert Enum.at(requests, 0).url ==
               "https://haraka.example.test/api/v1/dkim/domains/elektrine.test"

      assert Enum.at(requests, 1).url == "https://haraka.example.test/api/v1/dkim/domains/z.org"
    end

    test "shows lookup errors when Haraka does not provide DKIM data", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()

      MockHarakaHTTPClient.put_responses([
        {:ok, %Finch.Response{status: 404, body: ""}},
        {:ok, %Finch.Response{status: 503, body: Jason.encode!(%{"error" => "unavailable"})}}
      ])

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/haraka")

      html = html_response(conn, 200)

      assert html =~ "Haraka does not have DKIM data for elektrine.test."
      assert html =~ "Haraka DKIM lookup failed with status 503: unavailable"
    end
  end

  defp make_admin(user) do
    {:ok, admin_user} = Accounts.admin_update_user(user, %{is_admin: true})
    admin_user
  end

  defp with_elektrine_host(conn) do
    Map.put(conn, :host, "example.com")
  end

  defp log_in_as(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    now = System.system_time(:second)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:admin_auth_method, "password")
    |> Plug.Conn.put_session(:admin_access_expires_at, now + 900)
    |> Plug.Conn.put_session(:admin_elevated_until, now + 300)
  end
end
