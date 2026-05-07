defmodule Elektrine.ActivityPub.ActivityDeliveryWorkerTest do
  use Elektrine.DataCase, async: true
  use Oban.Testing, repo: Elektrine.Repo

  alias Elektrine.ActivityPub.ActivityDeliveryWorker

  test "discards missing deliveries" do
    assert {:discard, :missing_delivery} =
             ActivityDeliveryWorker.perform(%Oban.Job{args: %{"delivery_id" => -1}})
  end

  test "enqueue_many keeps one incomplete job per delivery" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      ActivityDeliveryWorker.enqueue_many([123, 123])
      ActivityDeliveryWorker.enqueue_many([123])

      assert [_job] =
               all_enqueued(worker: ActivityDeliveryWorker, args: %{"delivery_id" => 123})
    end)
  end
end
