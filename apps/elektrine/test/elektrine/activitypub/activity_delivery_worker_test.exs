defmodule Elektrine.ActivityPub.ActivityDeliveryWorkerTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.ActivityPub.ActivityDeliveryWorker

  test "discards missing deliveries" do
    assert {:discard, :missing_delivery} =
             ActivityDeliveryWorker.perform(%Oban.Job{args: %{"delivery_id" => -1}})
  end
end
