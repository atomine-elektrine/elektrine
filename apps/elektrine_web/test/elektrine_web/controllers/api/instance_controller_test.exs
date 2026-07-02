defmodule ElektrineWeb.API.InstanceControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.Instance
  alias Elektrine.Repo

  describe "show_v1/2" do
    test "returns public instance metadata", %{conn: conn} do
      conn = get(conn, "/api/v1/instance")

      assert %{
               "uri" => "www.example.com",
               "title" => "Elektrine",
               "registrations" => false,
               "configuration" => %{
                 "statuses" => %{
                   "max_characters" => 5000,
                   "max_media_attachments" => 4
                 },
                 "media_attachments" => %{
                   "image_size_limit" => upload_limit,
                   "video_size_limit" => upload_limit
                 },
                 "polls" => %{"max_options" => 4}
               },
               "max_toot_chars" => 5000,
               "max_media_attachments" => 4,
               "upload_limit" => upload_limit,
               "pleroma" => %{
                 "metadata" => %{
                   "features" => features,
                   "fields_limits" => %{"max_fields" => 4},
                   "post_formats" => ["text/plain", "text/html"]
                 },
                 "stats" => %{"mau" => mau}
               },
               "stats" => %{
                 "user_count" => user_count,
                 "status_count" => status_count
               }
             } = json_response(conn, 200)

      assert is_integer(upload_limit)
      assert is_integer(user_count)
      assert is_integer(status_count)
      assert is_integer(mau)
      assert "quote_posting" in features
      assert "pleroma:bookmark_folders" in features
      assert "pleroma_emoji_reactions" in features
    end
  end

  describe "show_v2/2" do
    test "returns v2 public instance metadata", %{conn: conn} do
      conn = get(conn, "/api/v2/instance")

      assert %{
               "domain" => "www.example.com",
               "title" => "Elektrine",
               "registrations" => %{
                 "enabled" => false,
                 "approval_required" => true
               },
               "configuration" => %{
                 "statuses" => %{"characters_reserved_per_url" => 23},
                 "translation" => %{"enabled" => false}
               },
               "pleroma" => %{
                 "metadata" => %{"features" => features},
                 "stats" => %{"mau" => mau}
               },
               "usage" => %{"users" => %{"active_month" => active_user_count}}
             } = json_response(conn, 200)

      assert is_integer(active_user_count)
      assert is_integer(mau)
      assert "pleroma_chat_messages" in features
      assert "editing" in features
    end
  end

  describe "metadata endpoints" do
    test "lists known peer domains", %{conn: conn} do
      remote_actor_fixture(%{username: "peeractor", domain: "peer-a.example"})

      %Instance{}
      |> Instance.changeset(%{domain: "peer-b.example"})
      |> Repo.insert!()

      conn = get(conn, "/api/v1/instance/peers")

      assert "peer-a.example" in json_response(conn, 200)
      assert "peer-b.example" in json_response(conn, 200)
    end

    test "lists configured public rules", %{conn: conn} do
      Application.put_env(:elektrine, :instance_rules, [
        "No spam.",
        %{id: "conduct", text: "Be decent.", hint: "Use judgment."}
      ])

      on_exit(fn -> Application.delete_env(:elektrine, :instance_rules) end)

      conn = get(conn, "/api/v1/instance/rules")

      assert [
               %{"id" => "1", "text" => "No spam.", "hint" => ""},
               %{"id" => "conduct", "text" => "Be decent.", "hint" => "Use judgment."}
             ] = json_response(conn, 200)
    end

    test "lists public domain blocks", %{conn: conn} do
      %Instance{}
      |> Instance.changeset(%{
        domain: "blocked.example",
        blocked: true,
        reason: "spam"
      })
      |> Repo.insert!()

      %Instance{}
      |> Instance.changeset(%{
        domain: "quiet.example",
        silenced: true
      })
      |> Repo.insert!()

      conn = get(conn, "/api/v1/instance/domain_blocks")

      assert [
               %{
                 "domain" => "blocked.example",
                 "severity" => "suspend",
                 "comment" => "spam",
                 "digest" => digest
               },
               %{"domain" => "quiet.example", "severity" => "silence"}
             ] = json_response(conn, 200)

      assert is_binary(digest)
    end

    test "returns empty translation language matrix when translation is not configured", %{
      conn: conn
    } do
      conn = get(conn, "/api/v1/instance/translation_languages")

      assert %{} = json_response(conn, 200)
    end
  end

  defp remote_actor_fixture(attrs) do
    unique = System.unique_integer([:positive])
    username = Map.get(attrs, :username, "remote#{unique}")
    domain = Map.get(attrs, :domain, "remote#{unique}.example")

    defaults = %{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      display_name: username,
      summary: "",
      inbox_url: "https://#{domain}/inbox",
      outbox_url: "https://#{domain}/users/#{username}/outbox",
      public_key: "test-public-key-#{unique}",
      actor_type: "Person"
    }

    %Actor{}
    |> Actor.changeset(defaults)
    |> Repo.insert!()
  end
end
