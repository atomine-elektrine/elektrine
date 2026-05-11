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

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}
  end
end
