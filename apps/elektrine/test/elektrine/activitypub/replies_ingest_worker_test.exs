defmodule Elektrine.ActivityPub.RepliesIngestWorkerTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub.RepliesIngestWorker
  alias Elektrine.Repo
  alias Elektrine.SocialFixtures

  test "discards jobs for missing messages" do
    assert {:discard, :message_not_found} =
             RepliesIngestWorker.perform(%Oban.Job{args: %{"message_id" => -1}})
  end

  test "returns retryable errors when remote fetch fails" do
    user = user_fixture()

    message =
      SocialFixtures.post_fixture(%{user: user})
      |> then(fn post ->
        Ecto.Changeset.change(post, activitypub_id: "http://127.0.0.1/replies-fetch-test")
      end)
      |> Repo.update!()

    assert {:error, _reason} =
             RepliesIngestWorker.perform(%Oban.Job{args: %{"message_id" => message.id}})
  end
end
