defmodule Elektrine.Social.DraftsTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Repo
  alias Elektrine.Social
  alias Elektrine.Social.Drafts
  alias Elektrine.Social.Message

  describe "scheduled drafts" do
    setup do
      previous_config = Application.get_env(:elektrine_social, Elektrine.Social.Drafts)

      Application.put_env(:elektrine_social, Elektrine.Social.Drafts,
        min_offset_seconds: 300,
        daily_user_limit: 2,
        total_user_limit: 3
      )

      on_exit(fn ->
        if previous_config do
          Application.put_env(:elektrine_social, Elektrine.Social.Drafts, previous_config)
        else
          Application.delete_env(:elektrine_social, Elektrine.Social.Drafts)
        end
      end)
    end

    test "scheduled drafts stay hidden from public timeline until published" do
      user = user_fixture()

      scheduled_at =
        DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second)

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
      draft = due_scheduled_draft(user.id, content: "due scheduled post")

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
      draft = due_scheduled_draft(user.id, content: "sensitive scheduled post", sensitive: true)

      assert %{published: 1, failed: 0} = Drafts.publish_due_scheduled_drafts(limit: 10)

      published = Repo.get!(Message, draft.id)
      assert published.sensitive
    end

    test "lists and gets scheduled drafts separately from ordinary drafts" do
      user = user_fixture()

      scheduled_at =
        DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      {:ok, scheduled} =
        Drafts.create_draft(user.id,
          content: "scheduled via api",
          visibility: "public",
          scheduled_at: scheduled_at
        )

      {:ok, _plain} =
        Drafts.create_draft(user.id,
          content: "ordinary draft",
          visibility: "public"
        )

      assert [listed] = Drafts.list_scheduled_drafts(user.id, limit: 10)
      assert listed.id == scheduled.id
      assert Drafts.get_scheduled_draft(scheduled.id, user.id).id == scheduled.id
    end

    test "rejects scheduled drafts that are too soon" do
      user = user_fixture()

      scheduled_at =
        DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.truncate(:second)

      assert {:error, changeset} =
               Drafts.create_draft(user.id,
                 content: "too soon",
                 visibility: "public",
                 scheduled_at: scheduled_at
               )

      assert "must be at least 300 seconds from now" in errors_on(changeset).scheduled_at
    end

    test "enforces daily scheduled draft limit" do
      user = user_fixture()

      scheduled_at =
        DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      assert {:ok, _first} =
               Drafts.create_draft(user.id,
                 content: "first",
                 visibility: "public",
                 scheduled_at: scheduled_at
               )

      assert {:ok, _second} =
               Drafts.create_draft(user.id,
                 content: "second",
                 visibility: "public",
                 scheduled_at: DateTime.add(scheduled_at, 60, :second)
               )

      assert {:error, changeset} =
               Drafts.create_draft(user.id,
                 content: "third",
                 visibility: "public",
                 scheduled_at: DateTime.add(scheduled_at, 120, :second)
               )

      assert "daily limit exceeded" in errors_on(changeset).scheduled_at
    end

    test "enforces total scheduled draft limit" do
      user = user_fixture()
      base = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      for day <- 0..2 do
        assert {:ok, _draft} =
                 Drafts.create_draft(user.id,
                   content: "scheduled #{day}",
                   visibility: "public",
                   scheduled_at: DateTime.add(base, day, :day)
                 )
      end

      assert {:error, changeset} =
               Drafts.create_draft(user.id,
                 content: "one too many",
                 visibility: "public",
                 scheduled_at: DateTime.add(base, 3, :day)
               )

      assert "total limit exceeded" in errors_on(changeset).scheduled_at
    end

    test "validates scheduled draft updates when rescheduling" do
      user = user_fixture()

      scheduled_at =
        DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      {:ok, draft} =
        Drafts.create_draft(user.id,
          content: "reschedule me",
          visibility: "public",
          scheduled_at: scheduled_at
        )

      too_soon = DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.truncate(:second)

      assert {:error, changeset} =
               Drafts.update_scheduled_draft(draft.id, user.id, scheduled_at: too_soon)

      assert "must be at least 300 seconds from now" in errors_on(changeset).scheduled_at
    end
  end

  defp due_scheduled_draft(user_id, opts) do
    scheduled_at = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second)
    due_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    {:ok, draft} =
      Drafts.create_draft(user_id,
        content: Keyword.fetch!(opts, :content),
        visibility: Keyword.get(opts, :visibility, "public"),
        sensitive: Keyword.get(opts, :sensitive, false),
        scheduled_at: scheduled_at
      )

    draft
    |> change(%{scheduled_at: due_at})
    |> Repo.update!()
  end
end
