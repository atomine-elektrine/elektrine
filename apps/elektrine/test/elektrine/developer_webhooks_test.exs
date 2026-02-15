defmodule Elektrine.DeveloperWebhooksTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.Developer

  describe "webhook management" do
    test "creates, lists, and deletes webhooks" do
      user = user_fixture()

      attrs = %{
        name: "Test Hook",
        url: "https://example.com/webhook",
        events: ["post.created", "follow.new"]
      }

      assert {:ok, webhook} = Developer.create_webhook(user.id, attrs)
      assert webhook.user_id == user.id
      assert webhook.enabled
      assert is_binary(webhook.secret)
      assert webhook.secret != ""

      webhooks = Developer.list_webhooks(user.id)
      assert Enum.any?(webhooks, &(&1.id == webhook.id))

      assert {:ok, _deleted} = Developer.delete_webhook(user.id, webhook.id)
      refute Enum.any?(Developer.list_webhooks(user.id), &(&1.id == webhook.id))
    end

    test "rejects non-https urls outside localhost allowance" do
      user = user_fixture()

      assert {:error, changeset} =
               Developer.create_webhook(user.id, %{
                 name: "Bad Hook",
                 url: "http://example.com/insecure",
                 events: ["post.created"]
               })

      assert "must be a valid HTTPS URL" in errors_on(changeset).url
    end

    test "sends a test webhook and records delivery metadata" do
      user = user_fixture()

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listener)

      parent = self()

      Task.start(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        send(parent, {:webhook_request, request})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

      {:ok, webhook} =
        Developer.create_webhook(user.id, %{
          name: "Local Test Hook",
          url: "http://127.0.0.1:#{port}/webhook",
          events: ["post.created"]
        })

      assert {:ok, 200} = Developer.test_webhook(user.id, webhook.id)
      assert_receive {:webhook_request, raw_request}, 5_000
      assert raw_request =~ "POST /webhook HTTP/1.1"
      assert raw_request =~ "x-elektrine-signature: sha256="

      updated = Developer.get_webhook(user.id, webhook.id)
      assert updated.last_response_status == 200
      assert updated.last_error == nil
      assert updated.last_triggered_at != nil
    end
  end
end
