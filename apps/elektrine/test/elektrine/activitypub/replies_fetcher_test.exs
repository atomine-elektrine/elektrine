defmodule Elektrine.ActivityPub.RepliesFetcherTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub.RepliesFetcher
  alias Elektrine.Repo
  alias Elektrine.SocialFixtures

  test "returns message_not_found for missing full-thread backfill target" do
    assert {:error, :message_not_found} = RepliesFetcher.fetch_full_thread_for_message(-1)
  end

  test "returns no_activitypub_id when full-thread backfill target is local-only" do
    user = user_fixture()

    message =
      SocialFixtures.post_fixture(%{user: user})
      |> then(fn post ->
        Ecto.Changeset.change(post, activitypub_id: nil, activitypub_url: nil)
      end)
      |> Repo.update!()

    assert {:error, :no_activitypub_id} = RepliesFetcher.fetch_full_thread_for_message(message.id)
  end
end
