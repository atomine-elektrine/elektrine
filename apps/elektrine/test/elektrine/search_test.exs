defmodule Elektrine.SearchTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub.Actor
  alias Elektrine.Messaging.Message
  alias Elektrine.{Repo, Search}

  describe "global_search/3" do
    test "finds local people when the query starts with @" do
      unique = System.unique_integer([:positive])
      viewer = user_fixture(%{username: "viewer#{unique}"})
      person = user_fixture(%{username: "testuser#{unique}"})

      results = Search.global_search(viewer, "@#{person.handle}", limit: 10).results

      assert Enum.any?(results, fn result ->
               result.type == "person" and result.content == "@#{person.handle}" and
                 result.url == "/#{person.handle}"
             end)
    end

    test "matches federated actor handles with a leading @" do
      unique = System.unique_integer([:positive])
      viewer = user_fixture(%{username: "viewerfed#{unique}"})
      actor = remote_actor_fixture("remote#{unique}", "example.com")

      actor
      |> federated_post_fixture(%{
        activitypub_id: "https://example.com/activities/#{unique}",
        content: "Federated post for search"
      })

      results =
        Search.global_search(viewer, "@#{actor.username}@#{actor.domain}", limit: 10).results

      assert Enum.any?(results, fn result ->
               result.type == "federated" and result.actor_username == actor.username and
                 result.actor_domain == actor.domain
             end)
    end
  end

  describe "get_suggestions/3" do
    test "suggests people for @-prefixed partial queries" do
      unique = System.unique_integer([:positive])
      viewer = user_fixture(%{username: "viewersuggest#{unique}"})
      person = user_fixture(%{username: "testsuggest#{unique}"})

      suggestions = Search.get_suggestions(viewer, "@tests", 10)

      assert Enum.any?(suggestions, fn suggestion ->
               suggestion.type == "person" and suggestion.text == "@#{person.handle}"
             end)
    end
  end

  defp remote_actor_fixture(username, domain) do
    %Actor{}
    |> Actor.changeset(%{
      uri: "https://#{domain}/users/#{username}",
      username: username,
      domain: domain,
      inbox_url: "https://#{domain}/users/#{username}/inbox",
      public_key: "test-public-key-#{username}"
    })
    |> Repo.insert!()
  end

  defp federated_post_fixture(actor, attrs) do
    attrs =
      Map.merge(
        %{
          activitypub_id:
            "https://#{actor.domain}/activities/#{System.unique_integer([:positive])}",
          content: "Federated search fixture",
          visibility: "public",
          post_type: "post",
          remote_actor_id: actor.id
        },
        attrs
      )

    %Message{}
    |> Message.federated_changeset(attrs)
    |> Repo.insert!()
  end
end
