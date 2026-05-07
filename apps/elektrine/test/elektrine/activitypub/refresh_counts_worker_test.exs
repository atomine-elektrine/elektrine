defmodule Elektrine.ActivityPub.RefreshCountsWorkerTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub.RefreshCountsWorker

  test "visible_refresh_candidate_ids/2 selects visible federated ActivityPub posts" do
    posts = [
      %{id: 1, federated: true, activitypub_id: "https://remote.example/statuses/1"},
      %{id: 1, federated: true, activitypub_id: "https://remote.example/statuses/1"},
      %{
        id: 2,
        federated: true,
        activitypub_id: "",
        activitypub_url: "https://remote.example/@a/2"
      },
      %{id: 3, federated: false, activitypub_id: "https://remote.example/statuses/3"},
      %{id: nil, federated: true, activitypub_id: "https://remote.example/statuses/4"},
      %{id: 5, federated: true, activitypub_id: ""},
      %{"id" => 6, "federated" => true, "activitypub_id" => "https://remote.example/statuses/6"}
    ]

    assert RefreshCountsWorker.visible_refresh_candidate_ids(posts, limit: 10) == [1, 2, 6]
    assert RefreshCountsWorker.visible_refresh_candidate_ids(posts, limit: 2) == [1, 2]
    assert RefreshCountsWorker.visible_refresh_candidate_ids(posts, limit: 0) == []
    assert RefreshCountsWorker.visible_refresh_candidate_ids(:not_posts, limit: 10) == []
  end
end
