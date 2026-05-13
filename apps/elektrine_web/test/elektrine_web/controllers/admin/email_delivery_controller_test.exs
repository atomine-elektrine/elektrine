defmodule ElektrineWeb.Admin.EmailDeliveryControllerTest do
  use ElektrineWeb.ConnCase
  use Oban.Testing, repo: Elektrine.Repo

  alias Elektrine.Accounts
  alias Elektrine.AccountsFixtures
  alias Elektrine.Email.ExternalDelivery
  alias Elektrine.Email.ExternalDeliveryControl
  alias Elektrine.Email.ExternalDeliveryWorker
  alias Elektrine.Email.InternalDelivery
  alias Elektrine.Email.InternalDeliveryWorker
  alias Elektrine.Email.Message
  alias Elektrine.Email.Suppressions
  alias Elektrine.EmailFixtures

  @admin_user_agent "email-delivery-controller-test"

  describe "GET /pripyat/email-delivery" do
    test "renders external delivery metrics and recent deliveries", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()
      delivery = external_delivery_fixture(status: "deferred")

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/email-delivery")

      html = html_response(conn, 200)
      assert html =~ "Email Delivery"
      assert html =~ "Queue Depth"
      assert html =~ delivery.recipient
      assert html =~ delivery.trace_id
    end

    test "renders internal delivery rows", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()
      delivery = internal_delivery_fixture(status: "failed")

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> get("/pripyat/email-delivery")

      html = html_response(conn, 200)
      assert html =~ "Internal Deliveries"
      assert html =~ delivery.recipient
      assert html =~ "failed"
    end
  end

  describe "admin delivery controls" do
    test "pauses and resumes outbound delivery by domain", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> admin_post(admin, "/pripyat/email-delivery/pause", %{
          "scope_type" => "domain",
          "scope_value" => "Remote.Test",
          "reason" => "temporary provider issue"
        })

      assert redirected_to(conn) == "/pripyat/email-delivery"

      control = ExternalDeliveryControl.get("domain", "remote.test")
      assert control.active
      assert control.reason == "temporary provider issue"
      assert control.paused_by_id == admin.id

      conn =
        build_conn()
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> admin_post(admin, "/pripyat/email-delivery/resume", %{
          "scope_type" => "domain",
          "scope_value" => "remote.test"
        })

      assert redirected_to(conn) == "/pripyat/email-delivery"
      refute ExternalDeliveryControl.get("domain", "remote.test").active
    end

    test "requeues a failed delivery", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()
      delivery = external_delivery_fixture(status: "failed")

      Oban.Testing.with_testing_mode(:manual, fn ->
        conn =
          conn
          |> with_elektrine_host()
          |> log_in_as(admin)
          |> admin_post(admin, "/pripyat/email-delivery/requeue/#{delivery.id}")

        assert redirected_to(conn) == "/pripyat/email-delivery"
        assert ExternalDelivery.get(delivery.id).status == "pending"

        assert_enqueued(
          worker: ExternalDeliveryWorker,
          args: %{"delivery_id" => delivery.id}
        )
      end)
    end

    test "requeues a failed internal delivery", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()
      delivery = internal_delivery_fixture(status: "failed")

      Oban.Testing.with_testing_mode(:manual, fn ->
        conn =
          conn
          |> with_elektrine_host()
          |> log_in_as(admin)
          |> admin_post(admin, "/pripyat/email-delivery/internal/requeue/#{delivery.id}")

        assert redirected_to(conn) == "/pripyat/email-delivery"
        assert InternalDelivery.get(delivery.id).status == "pending"

        assert_enqueued(
          worker: InternalDeliveryWorker,
          args: %{"delivery_id" => delivery.id}
        )
      end)
    end

    test "suppresses and unsuppresses a recipient", %{conn: conn} do
      admin = AccountsFixtures.user_fixture() |> make_admin()
      user = AccountsFixtures.user_fixture()

      conn =
        conn
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> admin_post(admin, "/pripyat/email-delivery/suppress", %{
          "user_id" => Integer.to_string(user.id),
          "email" => "Recipient@Remote.Test",
          "reason" => "manual"
        })

      assert redirected_to(conn) == "/pripyat/email-delivery"
      assert Suppressions.suppressed?(user.id, "recipient@remote.test")

      conn =
        build_conn()
        |> with_elektrine_host()
        |> log_in_as(admin)
        |> admin_post(admin, "/pripyat/email-delivery/unsuppress", %{
          "user_id" => Integer.to_string(user.id),
          "email" => "recipient@remote.test"
        })

      assert redirected_to(conn) == "/pripyat/email-delivery"
      refute Suppressions.suppressed?(user.id, "recipient@remote.test")
    end
  end

  defp external_delivery_fixture(attrs) do
    attrs = Map.new(attrs)

    user = AccountsFixtures.user_fixture()
    mailbox = EmailFixtures.mailbox_fixture(%{user_id: user.id, email: unique_email()})
    recipient = Map.get(attrs, :recipient, "recipient@remote.test")

    sent_message =
      sent_message_fixture(%{
        mailbox_id: mailbox.id,
        from: mailbox.email,
        to: recipient,
        message_id: "admin-delivery-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, delivery, _created} =
      ExternalDelivery.create_or_get(%{
        user_id: user.id,
        mailbox_id: mailbox.id,
        sent_message_id: sent_message.id,
        envelope_from: mailbox.email,
        to: [recipient],
        cc: [],
        bcc: [],
        recipient: recipient,
        recipient_type: "to",
        domain: recipient |> String.split("@") |> List.last(),
        trace_id: "admin-trace-#{System.unique_integer([:positive])}",
        params: %{
          "from" => mailbox.email,
          "to" => [recipient],
          "subject" => "Admin delivery test",
          "text_body" => "hello"
        },
        status: Map.get(attrs, :status, "pending")
      })

    delivery
  end

  defp internal_delivery_fixture(attrs) do
    attrs = Map.new(attrs)

    user = AccountsFixtures.user_fixture()
    recipient_user = AccountsFixtures.user_fixture()
    mailbox = EmailFixtures.mailbox_fixture(%{user_id: user.id, email: unique_email()})

    recipient_mailbox =
      EmailFixtures.mailbox_fixture(%{user_id: recipient_user.id, email: unique_email()})

    sent_message =
      sent_message_fixture(%{
        mailbox_id: mailbox.id,
        from: mailbox.email,
        to: recipient_mailbox.email,
        message_id: "admin-internal-delivery-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, delivery, _created} =
      InternalDelivery.create_or_get(%{
        user_id: user.id,
        mailbox_id: mailbox.id,
        sent_message_id: sent_message.id,
        recipient_mailbox_id: recipient_mailbox.id,
        recipient: recipient_mailbox.email,
        recipient_type: "to",
        params: %{
          "from" => mailbox.email,
          "to" => recipient_mailbox.email,
          "subject" => "Admin internal delivery test",
          "text_body" => "hello",
          "mailbox_id" => recipient_mailbox.id,
          "status" => "received"
        },
        status: Map.get(attrs, :status, "pending")
      })

    delivery
  end

  defp unique_email do
    "sender#{System.unique_integer([:positive])}@example.com"
  end

  defp sent_message_fixture(attrs) do
    attrs =
      Map.merge(
        %{
          status: "sent",
          subject: "Admin delivery test",
          text_body: "hello",
          html_body: "<p>hello</p>",
          read: true,
          spam: false,
          archived: false,
          deleted: false
        },
        attrs
      )

    %Message{}
    |> Message.changeset(attrs)
    |> Elektrine.Repo.insert!()
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
    |> Plug.Conn.put_req_header("user-agent", @admin_user_agent)
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:admin_auth_method, "password")
    |> Plug.Conn.put_session(:admin_access_expires_at, now + 900)
    |> Plug.Conn.put_session(:admin_elevated_until, now + 300)
    |> Plug.Conn.put_session(:admin_device_fingerprint, admin_request_fingerprint())
  end

  defp admin_post(conn, user, path, params \\ %{}) do
    grant = ElektrineWeb.AdminSecurity.issue_action_grant(conn, user, "POST", path)
    post(conn, path, Map.put(params, "_admin_action_grant", grant))
  end

  defp admin_request_fingerprint do
    :crypto.hash(:sha256, "#{@admin_user_agent}|||") |> Base.url_encode64(padding: false)
  end
end
