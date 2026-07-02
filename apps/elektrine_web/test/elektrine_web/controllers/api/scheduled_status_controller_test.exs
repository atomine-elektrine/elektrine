defmodule ElektrineWeb.API.ScheduledStatusControllerTest do
  use ElektrineWeb.ConnCase, async: false

  import Elektrine.AccountsFixtures

  alias Elektrine.Repo
  alias Elektrine.Social.Drafts
  alias Elektrine.Social.Message
  alias ElektrineWeb.API.ScheduledStatusController

  setup do
    previous_config = Application.get_env(:elektrine_social, Elektrine.Social.Drafts)

    Application.put_env(:elektrine_social, Elektrine.Social.Drafts,
      min_offset_seconds: 300,
      daily_user_limit: 25,
      total_user_limit: 300
    )

    on_exit(fn ->
      if previous_config do
        Application.put_env(:elektrine_social, Elektrine.Social.Drafts, previous_config)
      else
        Application.delete_env(:elektrine_social, Elektrine.Social.Drafts)
      end
    end)
  end

  describe "create/2" do
    test "creates a scheduled status", %{conn: conn} do
      user = user_fixture()
      scheduled_at = future_iso8601(600)

      conn =
        conn
        |> assign(:current_user, user)
        |> ScheduledStatusController.create(%{
          "status" => "queued post",
          "visibility" => "public",
          "scheduled_at" => scheduled_at
        })

      assert %{
               "id" => id,
               "scheduled_at" => ^scheduled_at,
               "params" => %{"text" => "queued post", "visibility" => "public"}
             } = json_response(conn, 201)

      draft = Repo.get!(Message, String.to_integer(id))
      assert draft.is_draft
      assert draft.sender_id == user.id
    end

    test "rejects a scheduled status that is too soon", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> assign(:current_user, user)
        |> ScheduledStatusController.create(%{
          "status" => "too soon",
          "scheduled_at" => future_iso8601(120)
        })

      assert %{"errors" => errors} = json_response(conn, 422)
      assert inspect(errors) =~ "scheduled_at"
    end
  end

  describe "scheduled status lifecycle" do
    test "updates, blocks early publish, and deletes a scheduled status", %{conn: conn} do
      user = user_fixture()
      {:ok, draft} = scheduled_draft(user.id, "initial")
      rescheduled_at = future_iso8601(900)

      update_conn =
        conn
        |> assign(:current_user, user)
        |> ScheduledStatusController.update(%{
          "id" => to_string(draft.id),
          "status" => "updated",
          "scheduled_at" => rescheduled_at
        })

      assert %{"id" => id, "params" => %{"text" => "updated"}} = json_response(update_conn, 200)
      assert id == to_string(draft.id)

      publish_conn =
        build_conn()
        |> assign(:current_user, user)
        |> ScheduledStatusController.publish(%{"id" => to_string(draft.id)})

      assert %{"error" => "scheduled status is not due yet"} = json_response(publish_conn, 409)

      delete_conn =
        build_conn()
        |> assign(:current_user, user)
        |> ScheduledStatusController.delete(%{"id" => to_string(draft.id)})

      assert %{"deleted" => true, "id" => id} = json_response(delete_conn, 200)
      assert id == to_string(draft.id)
    end
  end

  defp scheduled_draft(user_id, content) do
    Drafts.create_draft(user_id,
      content: content,
      visibility: "public",
      scheduled_at: future_datetime(600)
    )
  end

  defp future_iso8601(seconds) do
    seconds
    |> future_datetime()
    |> DateTime.to_iso8601()
  end

  defp future_datetime(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)
  end
end
