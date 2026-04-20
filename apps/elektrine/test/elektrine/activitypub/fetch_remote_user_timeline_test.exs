defmodule Elektrine.ActivityPub.FetchRemoteUserTimelineTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor

  defmodule FetcherStub do
    def fetch_object(url) do
      send(self(), {:fetch_object, url})

      case Process.get({:fetch_object_response, url}) do
        nil -> {:error, :missing_stub}
        response -> response
      end
    end
  end

  test "follows paginated outbox pages until enough top-level posts are collected" do
    actor = remote_actor_fixture()

    outbox_url = actor.outbox_url
    next_page_url = outbox_url <> "?page=2"

    Process.put(
      {:fetch_object_response, outbox_url},
      {:ok,
       %{
         "type" => "OrderedCollection",
         "first" => %{
           "orderedItems" => [
             %{
               "type" => "Create",
               "object" => %{
                 "id" => "https://remote.example/comment/1",
                 "type" => "Note",
                 "inReplyTo" => "https://remote.example/post/original"
               }
             }
           ],
           "next" => next_page_url
         }
       }}
    )

    Process.put(
      {:fetch_object_response, next_page_url},
      {:ok,
       %{
         "type" => "OrderedCollectionPage",
         "orderedItems" => [
           %{
             "type" => "Create",
             "object" => %{
               "id" => "https://remote.example/post/1",
               "type" => "Page"
             }
           },
           %{
             "type" => "Create",
             "object" => %{
               "id" => "https://remote.example/post/2",
               "type" => "Page"
             }
           }
         ]
       }}
    )

    assert {:ok, posts} =
             ActivityPub.fetch_remote_user_timeline(actor.id, limit: 2, fetcher: FetcherStub)

    assert Enum.map(posts, & &1["id"]) == [
             "https://remote.example/post/1",
             "https://remote.example/post/2"
           ]

    assert_received {:fetch_object, ^outbox_url}
    assert_received {:fetch_object, ^next_page_url}
  end

  defp remote_actor_fixture do
    unique = System.unique_integer([:positive])

    %Actor{}
    |> Actor.changeset(%{
      uri: "https://remote.example/users/alice-#{unique}",
      username: "alice#{unique}",
      domain: "remote.example",
      inbox_url: "https://remote.example/inbox",
      outbox_url: "https://remote.example/outbox/#{unique}",
      public_key: "-----BEGIN PUBLIC KEY-----test-key-----END PUBLIC KEY-----",
      last_fetched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end
end
