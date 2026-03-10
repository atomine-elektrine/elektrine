defmodule ElektrineWeb.EmailLive.ComposeTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email
  alias Elektrine.Email.Contact
  alias Elektrine.Repo

  defp log_in_user(conn, user) do
    token = Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", user.id)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "shows protected delivery as available when a known contact has a key", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    recipient_email = "secure#{System.unique_integer([:positive])}@example.com"

    %Contact{}
    |> Contact.changeset(%{
      user_id: user.id,
      name: "Secure Contact",
      email: recipient_email
    })
    |> Ecto.Changeset.change(%{pgp_public_key: "contact test key"})
    |> Repo.insert!()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email/compose?to=#{recipient_email}")

    assert html =~ "Protected Delivery"
    assert html =~ "Public keys are available for all 1 recipients."
    assert html =~ "Encrypt when possible"
  end

  test "shows missing recipient keys in protected delivery status", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    missing_email = "missing#{System.unique_integer([:positive])}@example.com"

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email/compose?to=#{missing_email}")

    assert html =~ "Protected Delivery"
    assert html =~ "Public keys are available for 0 of 1 recipients."
    assert html =~ "Missing keys for:"
    assert html =~ missing_email
  end

  test "shows inline unlock controls when replying to a protected message", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = private_mailbox_fixture(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Private thread",
        text_body: "Protected body",
        html_body: "<p>Protected body</p>",
        message_id: "<compose-private-#{System.unique_integer([:positive])}@example.com>"
      })

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email/compose?mode=reply&message_id=#{message.id}")

    assert html =~ "Protected Original Message"
    assert html =~ "Unlock this mailbox in the current tab"
  end

  defp private_mailbox_fixture(user) do
    mailbox =
      Email.get_user_mailbox(user.id) ||
        case Email.ensure_user_has_mailbox(user) do
          {:ok, mailbox} -> mailbox
          mailbox -> mailbox
        end

    {:ok, mailbox} =
      Email.update_mailbox_private_storage(mailbox, %{
        private_storage_enabled: true,
        private_storage_public_key: public_key_pem(),
        private_storage_wrapped_private_key: wrapped_payload(),
        private_storage_verifier: wrapped_payload()
      })

    mailbox
  end

  defp wrapped_payload do
    %{
      "version" => 1,
      "algorithm" => "AES-GCM",
      "kdf" => "scrypt",
      "n" => 16_384,
      "r" => 8,
      "p" => 1,
      "salt" => Base.encode64("1234567890123456"),
      "iv" => Base.encode64("123456789012"),
      "ciphertext" => Base.encode64("ciphertext-payload")
    }
  end

  defp public_key_pem do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _e1, _e2, _c, _other} = private_key
    public_key = {:RSAPublicKey, modulus, exponent}

    :public_key.pem_encode([:public_key.pem_entry_encode(:SubjectPublicKeyInfo, public_key)])
  end
end
