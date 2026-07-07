defmodule Elektrine.ActivityPub.SignatureRetryWorkerTest do
  use Elektrine.DataCase, async: true
  use Oban.Testing, repo: Elektrine.Repo

  alias Elektrine.ActivityPub.SignatureRetryWorker

  test "enqueue stores request headers in JSON-safe form" do
    conn =
      Plug.Test.conn(:post, "/inbox?source=test", %{})
      |> Map.put(:req_headers, [
        {"host", "elektrine.com"},
        {"signature", "keyId=\"https://remote.example/actor#main-key\""}
      ])

    activity = %{
      "id" => "https://remote.example/activities/1",
      "actor" => "https://remote.example/actor"
    }

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _job} =
               SignatureRetryWorker.enqueue(activity, "https://remote.example/actor", conn, nil)

      assert [
               %Oban.Job{
                 args: %{
                   "req_headers" => [
                     ["host", "elektrine.com"],
                     ["signature", "keyId=\"https://remote.example/actor#main-key\""]
                   ]
                 }
               }
             ] = all_enqueued(worker: SignatureRetryWorker)
    end)
  end
end
