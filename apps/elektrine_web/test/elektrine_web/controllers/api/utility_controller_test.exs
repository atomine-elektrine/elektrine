defmodule ElektrineWeb.API.UtilityControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Emojis.CustomEmoji
  alias Elektrine.Repo
  alias ElektrineWeb.API.UtilityController

  describe "public utility endpoints" do
    test "returns frontend configuration map", %{conn: conn} do
      previous = Application.get_env(:elektrine, :frontend_configurations)

      Application.put_env(:elektrine, :frontend_configurations,
        web: %{theme: "system"},
        mobile: %{compact: true}
      )

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:elektrine, :frontend_configurations)
        else
          Application.put_env(:elektrine, :frontend_configurations, previous)
        end
      end)

      conn = get(conn, "/api/pleroma/frontend_configurations")

      assert %{
               "web" => %{"theme" => "system"},
               "mobile" => %{"compact" => true}
             } = json_response(conn, 200)
    end

    test "returns available preferred frontend choices", %{conn: conn} do
      previous = Application.get_env(:elektrine, :frontends)

      Application.put_env(:elektrine, :frontends,
        pickable: ["web/stable", "minimal/latest", :invalid]
      )

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:elektrine, :frontends)
        else
          Application.put_env(:elektrine, :frontends, previous)
        end
      end)

      conn = get(conn, "/api/v1/pleroma/preferred_frontend/available")

      assert ["web/stable", "minimal/latest"] = json_response(conn, 200)
    end

    test "stores preferred frontend in a response cookie", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/pleroma/preferred_frontend", %{"frontend_name" => "web/stable"})

      assert %{"frontend_name" => "web/stable"} = json_response(conn, 200)

      assert %{
               "preferred_frontend" => %{
                 value: "web/stable",
                 max_age: 31_536_000,
                 path: "/"
               }
             } = conn.resp_cookies
    end

    test "rejects preferred frontend update without frontend_name", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put("/api/v1/pleroma/preferred_frontend", %{})

      assert %{"error" => "frontend_name is required"} = json_response(conn, 400)
      refute Map.has_key?(conn.resp_cookies, "preferred_frontend")
    end

    test "lists account aliases", %{conn: conn} do
      user = user_fixture(%{also_known_as: ["https://old.example/users/alice"]})

      conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.list_aliases(%{})

      assert %{"aliases" => ["https://old.example/users/alice"]} = json_response(conn, 200)
    end

    test "adds account alias metadata", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.add_alias(%{"alias" => "acct:alice@old.example"})

      assert %{"status" => "success"} = json_response(conn, 200)
      assert Accounts.get_user!(user.id).also_known_as == ["acct:alice@old.example"]
    end

    test "does not duplicate existing aliases", %{conn: conn} do
      user = user_fixture(%{also_known_as: ["acct:alice@old.example"]})

      conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.add_alias(%{"alias" => "acct:alice@old.example"})

      assert %{"status" => "success"} = json_response(conn, 200)
      assert Accounts.get_user!(user.id).also_known_as == ["acct:alice@old.example"]
    end

    test "deletes account alias metadata", %{conn: conn} do
      user =
        user_fixture(%{
          also_known_as: ["acct:alice@old.example", "https://old.example/users/alice"]
        })

      conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.delete_alias(%{"alias" => "acct:alice@old.example"})

      assert %{"status" => "success"} = json_response(conn, 200)
      assert Accounts.get_user!(user.id).also_known_as == ["https://old.example/users/alice"]
    end

    test "returns 404 when deleting an unknown alias", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.delete_alias(%{"alias" => "acct:missing@old.example"})

      assert %{"error" => "Account has no such alias."} = json_response(conn, 404)
    end

    test "rejects invalid aliases", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.add_alias(%{"alias" => "javascript:alert(1)"})

      assert %{
               "error" => "invalid_alias",
               "details" => %{"also_known_as" => [_ | _]}
             } = json_response(conn, 422)
    end

    test "requires alias parameter when adding or deleting aliases", %{conn: conn} do
      user = user_fixture()

      add_conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.add_alias(%{})

      assert %{"error" => "alias is required"} = json_response(add_conn, 400)

      delete_conn =
        build_conn()
        |> assign(:current_user, user)
        |> UtilityController.delete_alias(%{})

      assert %{"error" => "alias is required"} = json_response(delete_conn, 400)
    end

    test "moves account metadata with a verified password", %{conn: conn} do
      user = user_fixture()

      target_actor =
        remote_actor_fixture("alice", %{"alsoKnownAs" => [ActivityPub.actor_uri(user)]})

      conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.move_account(%{
          "target_account" => target_actor.uri,
          "password" => valid_user_password()
        })

      assert %{"status" => "success"} = json_response(conn, 200)
      assert Accounts.get_user!(user.id).moved_to == target_actor.uri
    end

    test "normalizes bare account move targets", %{conn: conn} do
      user = user_fixture()

      target_actor =
        remote_actor_fixture("alice", %{"alsoKnownAs" => [ActivityPub.actor_uri(user)]})

      conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.move_account(%{
          "target_account" => "#{target_actor.username}@#{target_actor.domain}",
          "password" => valid_user_password()
        })

      assert %{"status" => "success"} = json_response(conn, 200)
      assert Accounts.get_user!(user.id).moved_to == target_actor.uri
    end

    test "rejects account move with an invalid password", %{conn: conn} do
      user = user_fixture()

      target_actor =
        remote_actor_fixture("alice", %{"alsoKnownAs" => [ActivityPub.actor_uri(user)]})

      conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.move_account(%{
          "target_account" => target_actor.uri,
          "password" => "wrong password"
        })

      assert %{"error" => "invalid_password"} = json_response(conn, 403)
      assert is_nil(Accounts.get_user!(user.id).moved_to)
    end

    test "requires account move target and password", %{conn: conn} do
      user = user_fixture()

      target_conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.move_account(%{"password" => valid_user_password()})

      assert %{"error" => "target_account is required"} = json_response(target_conn, 400)

      password_conn =
        build_conn()
        |> assign(:current_user, user)
        |> UtilityController.move_account(%{
          "target_account" => "https://new.example/users/alice"
        })

      assert %{"error" => "password is required"} = json_response(password_conn, 400)
    end

    test "rejects invalid account move targets", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.move_account(%{
          "target_account" => "javascript:alert(1)",
          "password" => valid_user_password()
        })

      assert %{
               "error" => "invalid_move_target"
             } = json_response(conn, 422)
    end

    test "rejects account move targets that do not point back to the old actor", %{conn: conn} do
      user = user_fixture()
      target_actor = remote_actor_fixture("unverified", %{"alsoKnownAs" => []})

      conn =
        conn
        |> assign(:current_user, user)
        |> UtilityController.move_account(%{
          "target_account" => target_actor.uri,
          "password" => valid_user_password()
        })

      assert %{"error" => "move_target_not_verified"} = json_response(conn, 422)
      assert is_nil(Accounts.get_user!(user.id).moved_to)
    end

    test "returns legacy emoji map shape with tags", %{conn: conn} do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      Repo.insert!(%CustomEmoji{
        shortcode: "blobcat",
        image_url: "https://cdn.example/emojis/blobcat.png",
        category: "cats",
        visible_in_picker: true,
        disabled: false,
        inserted_at: now,
        updated_at: now
      })

      conn = get(conn, "/api/v1/pleroma/emoji")

      assert %{
               "blobcat" => %{
                 "image_url" => "https://cdn.example/emojis/blobcat.png",
                 "tags" => ["cats"]
               }
             } = json_response(conn, 200)
    end

    test "returns API captcha payload without exposing answer", %{conn: conn} do
      conn = get(conn, "/api/v1/pleroma/captcha")

      assert %{
               "type" => "native",
               "token" => token,
               "answer_data" => answer_data,
               "url" => "data:image/png;base64," <> encoded_image,
               "seconds_valid" => 300
             } = json_response(conn, 200)

      assert is_binary(token)
      assert answer_data == token
      assert {:ok, <<0x89, ?P, ?N, ?G, _rest::binary>>} = Base.decode64(encoded_image)
    end

    test "returns healthcheck when database is reachable", %{conn: conn} do
      conn = get(conn, "/api/v1/pleroma/healthcheck")

      assert %{
               "healthy" => true,
               "database" => "ok",
               "memory_used" => memory_used,
               "schedulers" => schedulers
             } = json_response(conn, 200)

      assert is_integer(memory_used)
      assert is_integer(schedulers)
    end
  end

  defp remote_actor_fixture(username, metadata) do
    unique = System.unique_integer([:positive])
    domain = "move-api-#{unique}.example"

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      inbox_url: "https://#{domain}/users/#{username}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
      metadata: metadata
    })
    |> Repo.insert!()
  end
end
