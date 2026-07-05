defmodule ElektrineWeb.MasterPasswordLiveTest do
  use ElektrineWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Elektrine.AccountsFixtures
  alias Elektrine.Vault

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

  test "setup requires the current account password", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/master-password")

    render_submit(view, "setup_master", %{
      "master" => %{
        "current_password" => "wrong password",
        "wrapped_dek" => Jason.encode!(wrapped_payload("dek")),
        "wrapped_dek_recovery" => Jason.encode!(wrapped_payload("recovery"))
      }
    })

    assert render(view) =~ "Current account password is incorrect."
    refute Vault.configured?(user.id)

    render_submit(view, "setup_master", %{
      "master" => %{
        "current_password" => AccountsFixtures.valid_user_password(),
        "wrapped_dek" => Jason.encode!(wrapped_payload("dek")),
        "wrapped_dek_recovery" => Jason.encode!(wrapped_payload("recovery"))
      }
    })

    assert render(view) =~ "Account password now unlocks encrypted data."
    assert Vault.configured?(user.id)
  end

  test "encrypted data route renders the account-password encryption page", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/encrypted-data")

    assert html =~ "Set up account-password encryption"
  end

  test "setup rejects direct submits before browser crypto fills payloads", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/master-password")

    render_submit(view, "setup_master", %{
      "master" => %{
        "current_password" => AccountsFixtures.valid_user_password(),
        "wrapped_dek" => "",
        "wrapped_dek_recovery" => ""
      }
    })

    assert render(view) =~ "Encrypted data was not generated in this browser."
    refute Vault.configured?(user.id)
  end

  test "recovery rewrap requires the current account password", %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    assert {:ok, _master_key} =
             Vault.setup(user.id, %{
               "wrapped_dek" => wrapped_payload("old-dek"),
               "wrapped_dek_recovery" => wrapped_payload("old-recovery")
             })

    {:ok, view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/account/master-password")

    render_submit(view, "rotate_master", %{
      "master" => %{
        "current_password" => "wrong password",
        "wrapped_dek" => Jason.encode!(wrapped_payload("new-dek")),
        "wrapped_dek_recovery" => Jason.encode!(wrapped_payload("new-recovery"))
      }
    })

    assert render(view) =~ "Current account password is incorrect."

    assert Vault.get(user.id).wrapped_dek["ciphertext"] ==
             wrapped_payload("old-dek")["ciphertext"]

    render_submit(view, "rotate_master", %{
      "master" => %{
        "current_password" => AccountsFixtures.valid_user_password(),
        "wrapped_dek" => Jason.encode!(wrapped_payload("new-dek")),
        "wrapped_dek_recovery" => Jason.encode!(wrapped_payload("new-recovery"))
      }
    })

    assert render(view) =~ "Encrypted data now unlocks with your current account password."

    assert Vault.get(user.id).wrapped_dek["ciphertext"] ==
             wrapped_payload("new-dek")["ciphertext"]
  end

  defp wrapped_payload(value) do
    %{
      "version" => 1,
      "algorithm" => "AES-GCM",
      "kdf" => "PBKDF2-SHA256",
      "iterations" => 210_000,
      "salt" => Base.encode64("1234567890123456"),
      "iv" => Base.encode64("123456789012"),
      "ciphertext" => Base.encode64("ciphertext:" <> value)
    }
  end
end
