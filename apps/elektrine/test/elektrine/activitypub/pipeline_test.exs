defmodule Elektrine.ActivityPub.PipelineTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.ActivityPub.Pipeline

  test "returns an error for URI-form Undo objects that cannot be fetched" do
    actor_uri = "https://remote.example/users/pipeline-undo-failure"

    activity = %{
      "id" => "https://remote.example/undo/#{System.unique_integer([:positive])}",
      "type" => "Undo",
      "actor" => actor_uri,
      "object" => "http://127.0.0.1/undo/#{System.unique_integer([:positive])}"
    }

    assert {:error, :undo_activity_fetch_failed} =
             Pipeline.process_incoming(activity, actor_uri, nil)
  end
end
