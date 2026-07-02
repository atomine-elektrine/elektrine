defmodule Elektrine.Social.ExpiredDataCleanupWorkerTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Repo
  alias Elektrine.Social.ExpiredDataCleanupWorker
  alias Elektrine.Social.LinkPreview

  test "prunes expired social filters and keeps active filters" do
    user = user_fixture()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    expired_at = DateTime.add(now, -60, :second)
    future_at = DateTime.add(now, 60, :second)

    Repo.insert_all("social_filters", [
      filter_row(user.id, "expired cleanup token", expired_at, now),
      filter_row(user.id, "active cleanup token", future_at, now),
      filter_row(user.id, "permanent cleanup token", nil, now)
    ])

    assert :ok = ExpiredDataCleanupWorker.perform(%Oban.Job{})

    assert filter_values() == ["active cleanup token", "permanent cleanup token"]
  end

  test "prunes stale failed link previews and keeps fresh or successful previews" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    stale = DateTime.add(now, -31, :day)
    fresh = DateTime.add(now, -1, :day)

    stale_failed =
      insert_preview!("https://example.com/stale-failed", "failed", stale)

    fresh_failed =
      insert_preview!("https://example.com/fresh-failed", "failed", fresh)

    old_success =
      insert_preview!("https://example.com/old-success", "success", stale)

    assert :ok = ExpiredDataCleanupWorker.perform(%Oban.Job{})

    refute Repo.get(LinkPreview, stale_failed.id)
    assert Repo.get(LinkPreview, fresh_failed.id)
    assert Repo.get(LinkPreview, old_success.id)
  end

  defp filter_row(user_id, value, expires_at, now) do
    %{
      user_id: user_id,
      kind: "keyword",
      value: value,
      contexts: [],
      action: "hide",
      whole_word: false,
      expires_at: expires_at,
      inserted_at: now,
      updated_at: now
    }
  end

  defp filter_values do
    %{rows: rows} =
      Repo.query!(
        """
        select value
        from social_filters
        where value like '% cleanup token'
        order by value
        """,
        []
      )

    Enum.map(rows, fn [value] -> value end)
  end

  defp insert_preview!(url, status, fetched_at) do
    %LinkPreview{}
    |> LinkPreview.changeset(%{
      url: url,
      status: status,
      fetched_at: fetched_at
    })
    |> Repo.insert!()
  end
end
