defmodule ElektrineSocialWeb.RemotePostLive.SeoTest do
  use ElektrineWeb.ConnCase, async: true

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging
  alias Elektrine.Repo

  test "remote post pages do not render cached federated content before strict origin fetch", %{
    conn: conn
  } do
    unique = System.unique_integer([:positive])
    domain = "remote.example"
    username = "poster#{unique}"

    actor =
      %Actor{}
      |> Actor.changeset(%{
        uri: "https://#{domain}/users/#{username}",
        username: username,
        domain: domain,
        inbox_url: "https://#{domain}/users/#{username}/inbox",
        public_key: "test-public-key-#{unique}"
      })
      |> Repo.insert!()

    {:ok, message} =
      Messaging.create_federated_message(%{
        title: "Cached remote title",
        content: "Cached remote content that should not appear in the dead render",
        visibility: "public",
        activitypub_id: "https://#{domain}/posts/#{unique}",
        activitypub_url: "https://#{domain}/posts/#{unique}",
        federated: true,
        remote_actor_id: actor.id
      })

    html =
      conn
      |> get("/remote/post/#{message.id}")
      |> html_response(200)

    refute html =~ "Cached remote title"
    refute html =~ "Cached remote content that should not appear in the dead render"
  end
end
