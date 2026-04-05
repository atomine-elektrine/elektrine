defmodule ElektrineEmailWeb.EmailLive.ShowPrivateMailboxTest do
  use ElektrineWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email

  defp log_in_user(conn, user) do
    token =
      Phoenix.Token.sign(ElektrineWeb.Endpoint, "user auth", %{
        "user_id" => user.id,
        "password_changed_at" =>
          user.last_password_change && DateTime.to_unix(user.last_password_change),
        "auth_valid_after" => user.auth_valid_after && DateTime.to_unix(user.auth_valid_after)
      })

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  test "shows protected placeholder for private mailbox messages", %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    mailbox = private_mailbox_fixture(user)

    {:ok, message} =
      Email.create_message(%{
        mailbox_id: mailbox.id,
        from: "sender@example.com",
        to: mailbox.email,
        subject: "Hidden details",
        text_body: "Stored privately",
        html_body: "<p>Stored privately</p>",
        message_id: "<private-show-#{System.unique_integer([:positive])}@example.com>"
      })

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/email/view/#{message.hash}")

    assert html =~ "Protected mailbox content"
    assert html =~ "Private Mailbox"
    assert html =~ "Unlock this mailbox in the current tab"
    assert html =~ "Unlock your mailbox in this tab to read this message."
    assert html =~ "Encrypted message"
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
