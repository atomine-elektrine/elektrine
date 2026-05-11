defmodule Elektrine.Social.DraftsTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Drafts
  alias Elektrine.Social.Message

  describe "scheduled drafts" do
    test "scheduled drafts stay hidden from public timeline until published" do
      user = user_fixture()
      scheduled_at = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)

      {:ok, draft} =
        Drafts.create_draft(user.id,
          content: "scheduled post",
          visibility: "public",
          scheduled_at: scheduled_at
        )

      post_ids = Social.get_public_timeline(limit: 20, user_id: user.id) |> Enum.map(& &1.id)
      refute draft.id in post_ids
    end

    test "publishes due scheduled drafts and clears scheduling metadata" do
      user = user_fixture()

      scheduled_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      {:ok, draft} =
        Drafts.create_draft(user.id,
          content: "due scheduled post",
          visibility: "public",
          scheduled_at: scheduled_at
        )

      assert %{published: 1, failed: 0} = Drafts.publish_due_scheduled_drafts(limit: 10)

      published = Repo.get!(Message, draft.id)
      refute published.is_draft
      assert is_nil(published.scheduled_at)

      post_ids = Social.get_public_timeline(limit: 20, user_id: user.id) |> Enum.map(& &1.id)
      assert draft.id in post_ids
    end

    test "does not manually publish scheduled drafts before their time" do
      user = user_fixture()

      scheduled_at =
        DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      {:ok, draft} =
        Drafts.create_draft(user.id,
          content: "not yet scheduled post",
          visibility: "public",
          scheduled_at: scheduled_at
        )

      assert {:error, :scheduled_for_future} = Drafts.publish_draft(draft.id, user.id)

      still_draft = Repo.get!(Message, draft.id)
      assert still_draft.is_draft
      assert still_draft.scheduled_at == scheduled_at
    end

    test "does not publish scheduled drafts before their time" do
      user = user_fixture()

      scheduled_at =
        DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      {:ok, draft} =
        Drafts.create_draft(user.id,
          content: "future scheduled post",
          visibility: "public",
          scheduled_at: scheduled_at
        )

      assert %{published: 0, failed: 0} = Drafts.publish_due_scheduled_drafts(limit: 10)

      still_draft = Repo.get!(Message, draft.id)
      assert still_draft.is_draft
      assert still_draft.scheduled_at == scheduled_at
    end

    test "preserves sensitive flag when publishing scheduled drafts" do
      user = user_fixture()

      scheduled_at =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      {:ok, draft} =
        Drafts.create_draft(user.id,
          content: "sensitive scheduled post",
          visibility: "public",
          sensitive: true,
          scheduled_at: scheduled_at
        )

      assert %{published: 1, failed: 0} = Drafts.publish_due_scheduled_drafts(limit: 10)

      published = Repo.get!(Message, draft.id)
      assert published.sensitive
    end
  end
end
