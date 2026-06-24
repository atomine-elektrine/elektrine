defmodule ElektrineWeb.UserSessionControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts.TrustedDevice
  alias Elektrine.Repo

  describe "trusted device login" do
    test "rejects legacy raw stored trusted-device tokens", %{conn: conn} do
      user = two_factor_user_fixture()
      raw_device_token = TrustedDevice.generate_device_token()

      insert_trusted_device!(user.id, raw_device_token)

      conn =
        conn
        |> put_req_cookie("device_token", raw_device_token)
        |> post(~p"/login", %{
          "user" => %{"username" => user.username, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/two_factor"
    end

    test "accepts hashed stored trusted-device tokens", %{conn: conn} do
      user = two_factor_user_fixture()
      raw_device_token = TrustedDevice.generate_device_token()

      insert_trusted_device!(user.id, TrustedDevice.hash_device_token(raw_device_token))

      conn =
        conn
        |> put_req_cookie("device_token", raw_device_token)
        |> post(~p"/login", %{
          "user" => %{"username" => user.username, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == "/onboarding"
    end
  end

  defp two_factor_user_fixture do
    {:ok, user} =
      user_fixture()
      |> Ecto.Changeset.change(%{
        two_factor_enabled: true,
        two_factor_secret: Base.encode64(:crypto.strong_rand_bytes(20))
      })
      |> Repo.update()

    user
  end

  defp insert_trusted_device!(user_id, stored_token) do
    expires_at = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

    %TrustedDevice{}
    |> TrustedDevice.changeset(%{
      user_id: user_id,
      device_token: stored_token,
      last_used_at: DateTime.utc_now() |> DateTime.truncate(:second),
      expires_at: expires_at
    })
    |> Repo.insert!()
  end
end
