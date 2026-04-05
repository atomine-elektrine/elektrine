defmodule Elektrine.Messaging.FederationOutboxWorkerTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Messaging.FederationOutboxWorker

  test "discards missing outbox rows" do
    assert {:discard, :not_found} =
             FederationOutboxWorker.perform(%Oban.Job{args: %{"outbox_event_id" => -1}})
  end
end
