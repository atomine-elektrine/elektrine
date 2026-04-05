defmodule Elektrine.RSS.FetchFeedWorkerTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.RSS.FetchFeedWorker

  test "discards missing feeds" do
    assert {:discard, :feed_not_found} =
             FetchFeedWorker.perform(%Oban.Job{args: %{"feed_id" => -1}})
  end
end
