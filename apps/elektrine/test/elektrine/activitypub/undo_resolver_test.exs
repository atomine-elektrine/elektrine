defmodule Elektrine.ActivityPub.UndoResolverTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.{Actor, UndoResolver}
  alias Elektrine.Repo
  alias Elektrine.SocialFixtures

  test "resolves stored remote EmojiReact activities without fetching" do
    user = AccountsFixtures.user_fixture()
    message = SocialFixtures.post_fixture(%{user: user, visibility: "public"})
    remote_actor = remote_actor_fixture("undo_resolver_reactor")
    reaction_id = "https://remote.example/reactions/#{System.unique_integer([:positive])}"
    object_id = "#{ActivityPub.instance_url()}/posts/#{message.id}"

    assert {:ok, _activity} =
             ActivityPub.create_activity(%{
               activity_id: reaction_id,
               activity_type: "EmojiReact",
               actor_uri: remote_actor.uri,
               object_id: object_id,
               data: %{
                 "id" => reaction_id,
                 "type" => "EmojiReact",
                 "actor" => remote_actor.uri,
                 "object" => object_id,
                 "content" => ":blobcat:"
               },
               local: false,
               processed: true
             })

    assert {:ok,
            %{
              "id" => ^reaction_id,
              "type" => "EmojiReact",
              "object" => ^object_id,
              "content" => ":blobcat:"
            }} = UndoResolver.resolve(reaction_id, remote_actor.uri)
  end

  test "does not resolve stored remote activities for a different actor" do
    user = AccountsFixtures.user_fixture()
    message = SocialFixtures.post_fixture(%{user: user, visibility: "public"})
    remote_actor = remote_actor_fixture("undo_resolver_owner")
    reaction_id = "https://remote.example/reactions/#{System.unique_integer([:positive])}"

    assert {:ok, _activity} =
             ActivityPub.create_activity(%{
               activity_id: reaction_id,
               activity_type: "EmojiReact",
               actor_uri: remote_actor.uri,
               object_id: "#{ActivityPub.instance_url()}/posts/#{message.id}",
               data: %{
                 "id" => reaction_id,
                 "type" => "EmojiReact",
                 "actor" => remote_actor.uri,
                 "object" => "#{ActivityPub.instance_url()}/posts/#{message.id}",
                 "content" => ":blobcat:"
               },
               local: false,
               processed: true
             })

    assert :not_found =
             UndoResolver.resolve(reaction_id, "https://remote.example/users/other-actor")
  end

  defp remote_actor_fixture(label) do
    unique_id = System.unique_integer([:positive])
    username = "#{label}#{unique_id}"

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://remote.example/users/#{username}",
      username: username,
      domain: "remote.example",
      inbox_url: "https://remote.example/users/#{username}/inbox",
      public_key: "-----BEGIN RSA PUBLIC KEY-----\nMOCK\n-----END RSA PUBLIC KEY-----\n",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
