defmodule ElektrineSocialWeb.TimelineLive.PostOperationsTest do
  use Elektrine.DataCase, async: false

  import Elektrine.AccountsFixtures
  import Elektrine.SocialFixtures

  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias ElektrineSocialWeb.TimelineLive.Operations.PostOperations

  test "admin delete requires recent admin confirmation" do
    previous_config = Application.get_env(:elektrine, :admin_security, [])

    Application.put_env(
      :elektrine,
      :admin_security,
      Keyword.put(previous_config, :require_passkey, false)
    )

    on_exit(fn -> Application.put_env(:elektrine, :admin_security, previous_config) end)

    admin = user_fixture() |> Ecto.Changeset.change(is_admin: true) |> Repo.update!()
    post = post_fixture()
    now = System.system_time(:second)

    socket =
      socket(%{
        current_user: admin,
        admin_auth_method: "password",
        admin_access_expires_at: now + 300,
        admin_elevated_until: now + 300
      })

    assert {:noreply, _socket} =
             PostOperations.handle_event(
               "delete_post_admin",
               %{"message_id" => Integer.to_string(post.id)},
               socket
             )

    refute Repo.get!(Message, post.id).deleted_at
  end

  test "malformed message action ids do not crash" do
    user = user_fixture()

    socket =
      socket(%{
        current_user: user,
        timeline_posts: [],
        filtered_posts: []
      })

    assert {:noreply, socket} =
             PostOperations.handle_event("delete_post", %{"message_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "You can only delete your own posts"

    assert {:noreply, socket} =
             PostOperations.handle_event("copy_post_link", %{"message_id" => "12abc"}, socket)

    assert {:noreply, socket} =
             PostOperations.handle_event("report_post", %{"message_id" => "12abc"}, socket)

    refute Map.has_key?(socket.assigns, :show_report_modal)
  end

  test "malformed admin delete id fails without touching posts" do
    previous_config = Application.get_env(:elektrine, :admin_security, [])

    Application.put_env(
      :elektrine,
      :admin_security,
      Keyword.put(previous_config, :require_passkey, false)
    )

    on_exit(fn -> Application.put_env(:elektrine, :admin_security, previous_config) end)

    admin = user_fixture() |> Ecto.Changeset.change(is_admin: true) |> Repo.update!()
    now = System.system_time(:second)

    socket =
      socket(%{
        current_user: admin,
        timeline_posts: [],
        filtered_posts: [],
        admin_auth_method: "password",
        admin_access_expires_at: now + 300,
        admin_elevated_until: now + 300,
        admin_last_resign_at: now
      })

    assert {:noreply, socket} =
             PostOperations.handle_event(
               "delete_post_admin",
               %{"message_id" => "12abc"},
               socket
             )

    assert socket.assigns.flash["error"] == "Failed to delete post"
  end

  test "malformed draft ids do not crash" do
    user = user_fixture()

    socket =
      socket(%{
        current_user: user,
        timeline_posts: [],
        user_drafts: []
      })

    assert {:noreply, socket} =
             PostOperations.handle_event("edit_draft", %{"draft_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Draft not found"

    assert {:noreply, socket} =
             PostOperations.handle_event("publish_draft", %{"draft_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Draft not found"

    assert {:noreply, socket} =
             PostOperations.handle_event("delete_draft", %{"draft_id" => "12abc"}, socket)

    assert socket.assigns.flash["error"] == "Draft not found"
  end

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}
  end
end
