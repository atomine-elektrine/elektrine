defmodule Elektrine.Social.LinkPreviewRefreshWorkerTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Repo
  alias Elektrine.Social.LinkPreview
  alias Elektrine.Social.LinkPreviewRefreshWorker

  test "selects stale successful previews only" do
    old = DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)
    fresh = DateTime.utc_now() |> DateTime.truncate(:second)

    stale =
      %LinkPreview{}
      |> LinkPreview.changeset(%{
        url: "https://example.com/stale",
        status: "success",
        fetched_at: old
      })
      |> Repo.insert!()

    %LinkPreview{}
    |> LinkPreview.changeset(%{
      url: "https://example.com/fresh",
      status: "success",
      fetched_at: fresh
    })
    |> Repo.insert!()

    %LinkPreview{}
    |> LinkPreview.changeset(%{
      url: "https://example.com/failed",
      status: "failed",
      fetched_at: old
    })
    |> Repo.insert!()

    assert [found] = LinkPreviewRefreshWorker.stale_previews(limit: 10, max_age_days: 7)
    assert found.id == stale.id
  end
end
