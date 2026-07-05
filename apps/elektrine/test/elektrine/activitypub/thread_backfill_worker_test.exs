defmodule Elektrine.ActivityPub.ThreadBackfillWorkerTest do
  use Elektrine.DataCase, async: true
  use Oban.Testing, repo: Elektrine.Repo

  alias Elektrine.ActivityPub.ThreadBackfillWorker

  test "forced retries are unique separately from automatic backfills" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      ThreadBackfillWorker.enqueue(123)
      ThreadBackfillWorker.enqueue(123, force: true)

      assert [_job] =
               all_enqueued(
                 worker: ThreadBackfillWorker,
                 args: %{"message_id" => 123, "force" => false}
               )

      assert [_job] =
               all_enqueued(
                 worker: ThreadBackfillWorker,
                 args: %{"message_id" => 123, "force" => true}
               )
    end)
  end
end
