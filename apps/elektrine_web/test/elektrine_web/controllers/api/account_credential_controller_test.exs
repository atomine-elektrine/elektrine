defmodule ElektrineWeb.API.AccountCredentialControllerTest do
  use ElektrineWeb.ConnCase, async: true

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Accounts
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo
  alias ElektrineWeb.API.AccountCredentialController

  describe "verify_credentials/2" do
    test "returns the current account with source metadata", %{conn: conn} do
      user = user_fixture(%{username: "verifyuser"})
      {:ok, user} = Accounts.update_user(user, %{default_post_visibility: "public"})
      follower = user_fixture()
      followed = user_fixture()
      pending_actor = remote_actor_fixture("pending.example")
      accepted_actor = remote_actor_fixture("accepted.example")
      {:ok, _profile} = Profiles.upsert_user_profile(user.id, %{description: "Verified note"})
      assert {:ok, _follow} = Profiles.follow_user(follower.id, user.id)
      assert {:ok, _follow} = Profiles.follow_user(user.id, followed.id)
      post = post_fixture(%{user: user, visibility: "public", content: "credential count"})

      %Follow{}
      |> Follow.changeset(%{
        followed_id: user.id,
        remote_actor_id: pending_actor.id,
        pending: true
      })
      |> Repo.insert!()

      %Follow{}
      |> Follow.changeset(%{
        followed_id: user.id,
        remote_actor_id: accepted_actor.id,
        pending: false
      })
      |> Repo.insert!()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountCredentialController.verify_credentials(%{})

      assert %{
               "id" => id,
               "username" => "verifyuser",
               "acct" => acct,
               "note" => "Verified note",
               "locked" => true,
               "followers_count" => 2,
               "following_count" => 1,
               "statuses_count" => 1,
               "last_status_at" => last_status_at,
               "fields" => [],
               "emojis" => [],
               "source" => %{
                 "note" => "Verified note",
                 "privacy" => "public",
                 "language" => "en",
                 "follow_requests_count" => 1
               }
             } = json_response(conn, 200)

      assert id == to_string(user.id)
      assert acct == user.handle
      assert last_status_at == date_iso(post.inserted_at)
    end
  end

  describe "update_credentials/2" do
    test "updates backed account and profile fields", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountCredentialController.update_credentials(%{
          "display_name" => "Updated Name",
          "note" => "Updated note",
          "avatar" => "/uploads/avatars/account.png",
          "header" => "/uploads/backgrounds/header.png",
          "locked" => "false",
          "source" => %{"privacy" => "public"},
          "bot" => "true"
        })

      assert %{
               "display_name" => "Updated Name",
               "note" => "Updated note",
               "avatar" => "/uploads/avatars/account.png",
               "header" => "/uploads/backgrounds/header.png",
               "locked" => false,
               "bot" => false,
               "source" => %{"privacy" => "public"}
             } = json_response(conn, 200)

      updated_user = Accounts.get_user!(user.id)
      profile = Profiles.get_user_profile(user.id)

      assert updated_user.display_name == "Updated Name"
      assert updated_user.avatar == "/uploads/avatars/account.png"
      assert updated_user.activitypub_manually_approve_followers == false
      assert updated_user.default_post_visibility == "public"
      assert profile.description == "Updated note"
      assert profile.banner_url == "/uploads/backgrounds/header.png"
    end

    test "maps private client privacy to followers visibility", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountCredentialController.update_credentials(%{
          "source" => %{"privacy" => "private"}
        })

      assert %{"source" => %{"privacy" => "followers"}} = json_response(conn, 200)
      assert Accounts.get_user!(user.id).default_post_visibility == "followers"
    end

    test "updates birthday metadata", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountCredentialController.update_credentials(%{
          "birthday" => "2001-02-12",
          "show_birthday" => "true"
        })

      assert %{
               "pleroma" => %{"birthday" => "2001-02-12"},
               "source" => %{"pleroma" => %{"show_birthday" => true}}
             } = json_response(conn, 200)

      updated_user = Accounts.get_user!(user.id)
      assert updated_user.birthday == ~D[2001-02-12]
      assert updated_user.show_birthday == true
    end

    test "updates account list privacy metadata", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountCredentialController.update_credentials(%{
          "hide_followers" => "true",
          "hide_follows" => "true",
          "hide_favorites" => "true"
        })

      assert %{
               "pleroma" => %{
                 "hide_followers" => true,
                 "hide_follows" => true,
                 "hide_favorites" => true
               },
               "source" => %{
                 "pleroma" => %{
                   "hide_followers" => true,
                   "hide_follows" => true,
                   "hide_favorites" => true
                 }
               }
             } = json_response(conn, 200)

      updated_user = Accounts.get_user!(user.id)
      assert updated_user.hide_followers == true
      assert updated_user.hide_follows == true
      assert updated_user.hide_favorites == true
    end

    test "updates account migration metadata", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountCredentialController.update_credentials(%{
          "also_known_as" => [
            "https://old.example/users/alice",
            "acct:alice@old.example",
            ""
          ],
          "moved_to" => "https://new.example/users/alice"
        })

      assert %{
               "pleroma" => %{
                 "also_known_as" => [
                   "https://old.example/users/alice",
                   "acct:alice@old.example"
                 ],
                 "moved_to" => "https://new.example/users/alice"
               }
             } = json_response(conn, 200)

      updated_user = Accounts.get_user!(user.id)

      assert updated_user.also_known_as == [
               "https://old.example/users/alice",
               "acct:alice@old.example"
             ]

      assert updated_user.moved_to == "https://new.example/users/alice"
    end

    test "rejects invalid account migration metadata", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountCredentialController.update_credentials(%{
          "also_known_as" => ["javascript:alert(1)"],
          "moved_to" => "ftp://new.example/users/alice"
        })

      assert %{
               "error" => "invalid_account_metadata",
               "details" => details
             } = json_response(conn, 422)

      assert Map.has_key?(details, "also_known_as")
      assert Map.has_key?(details, "moved_to")
    end

    test "clears birthday with empty string", %{conn: conn} do
      user = user_fixture(%{birthday: ~D[2001-02-12], show_birthday: true})

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountCredentialController.update_credentials(%{"birthday" => ""})

      assert %{"pleroma" => %{"birthday" => nil}} = json_response(conn, 200)
      assert Accounts.get_user!(user.id).birthday == nil
    end

    test "rejects future birthday", %{conn: conn} do
      user = user_fixture()
      future_date = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountCredentialController.update_credentials(%{"birthday" => future_date})

      assert %{
               "error" => "invalid_account_metadata",
               "details" => %{"birthday" => [_ | _]}
             } = json_response(conn, 422)
    end

    test "clears avatar and header with empty strings", %{conn: conn} do
      user = user_fixture()

      {:ok, user} = Accounts.update_user(user, %{avatar: "/uploads/avatars/account.png"})

      {:ok, _profile} =
        Profiles.upsert_user_profile(user.id, %{
          avatar_url: "/uploads/avatars/account.png",
          banner_url: "/uploads/backgrounds/header.png"
        })

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountCredentialController.update_credentials(%{
          "avatar" => "",
          "header" => ""
        })

      assert %{"avatar" => nil, "header" => nil} = json_response(conn, 200)
      assert Accounts.get_user!(user.id).avatar == nil

      profile = Profiles.get_user_profile(user.id)
      assert profile.avatar_url == nil
      assert profile.banner_url == nil
    end

    test "returns validation errors", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> AccountCredentialController.update_credentials(%{
          "display_name" => String.duplicate("x", 101)
        })

      assert %{
               "error" => "invalid_account_metadata",
               "details" => %{"display_name" => [_ | _]}
             } = json_response(conn, 422)
    end
  end

  defp remote_actor_fixture(domain) do
    unique = System.unique_integer([:positive])
    username = "remote#{unique}"

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      display_name: username,
      summary: "",
      inbox_url: "https://#{domain}/inbox",
      outbox_url: "https://#{domain}/users/#{username}/outbox",
      public_key: "test-public-key-#{unique}",
      actor_type: "Person"
    })
    |> Repo.insert!()
  end

  defp date_iso(%Date{} = date), do: Date.to_iso8601(date)
  defp date_iso(%DateTime{} = datetime), do: datetime |> DateTime.to_date() |> Date.to_iso8601()

  defp date_iso(%NaiveDateTime{} = datetime),
    do: datetime |> NaiveDateTime.to_date() |> Date.to_iso8601()
end
