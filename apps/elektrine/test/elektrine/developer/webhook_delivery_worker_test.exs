defmodule Elektrine.Developer.WebhookDeliveryWorkerTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Developer.WebhookDeliveryWorker

  test "discards missing delivery rows" do
    assert {:discard, :not_found} =
             WebhookDeliveryWorker.perform(%Oban.Job{args: %{"delivery_id" => -1}, attempt: 1})
  end
end
