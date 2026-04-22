defmodule ElektrineSocialWeb.RemoteUserLive.SeoTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging
  alias Elektrine.Repo

  test "remote user profiles render noindex robots metadata", %{conn: conn} do
    unique = System.unique_integer([:positive])
    username = "remote#{unique}"
    domain = "remote.example"

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      inbox_url: "https://#{domain}/users/#{username}/inbox",
      public_key: "test-public-key-#{unique}"
    })
    |> Repo.insert!()

    html =
      conn
      |> get("/remote/#{username}@#{domain}")
      |> html_response(200)

    assert html =~ ~s(<meta name="robots" content="noindex, nofollow")
  end

  test "remote user profiles do not render cached actor data before strict origin fetch", %{
    conn: conn
  } do
    unique = System.unique_integer([:positive])
    username = "cached#{unique}"
    domain = "remote.example"

    actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://#{domain}/users/#{username}",
        username: username,
        domain: domain,
        display_name: "Cached Remote User",
        inbox_url: "https://#{domain}/users/#{username}/inbox",
        public_key: "test-public-key-#{unique}"
      })
      |> Repo.insert!()

    {:ok, _message} =
      Messaging.create_federated_message(%{
        content: "Cached remote post that should not appear in dead render",
        visibility: "public",
        activitypub_id: "https://#{domain}/posts/#{unique}",
        activitypub_url: "https://#{domain}/posts/#{unique}",
        federated: true,
        remote_actor_id: actor.id
      })

    html =
      conn
      |> get("/remote/#{username}@#{domain}")
      |> html_response(200)

    assert html =~ "Loading profile..."
    refute html =~ "Cached Remote User"
    refute html =~ "Cached remote post that should not appear in dead render"
  end
end
