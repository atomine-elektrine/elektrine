defmodule ElektrineWeb.Admin.InviteCodesController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}
  plug :assign_timezone_and_format

  defp assign_timezone_and_format(conn, _opts) do
    current_user = conn.assigns[:current_user]

    timezone =
      if current_user && current_user.timezone, do: current_user.timezone, else: "Etc/UTC"

    time_format =
      if current_user && current_user.time_format, do: current_user.time_format, else: "12"

    conn
    |> assign(:timezone, timezone)
    |> assign(:time_format, time_format)
  end

  def index(conn, _params) do
    invite_codes = Accounts.list_invite_codes()
    stats = Accounts.get_invite_code_stats()
    invite_codes_enabled = Elektrine.System.invite_codes_enabled?()

    render(conn, :invite_codes,
      invite_codes: invite_codes,
      stats: stats,
      invite_codes_enabled: invite_codes_enabled
    )
  end

  def new(conn, _params) do
    changeset = Accounts.change_invite_code(%Elektrine.Accounts.InviteCode{})
    render(conn, :new_invite_code, changeset: changeset)
  end

  def create(conn, %{"invite_code" => invite_code_params}) do
    invite_code_params =
      Map.put(invite_code_params, "created_by_id", conn.assigns.current_user.id)

    case Accounts.create_invite_code(invite_code_params) do
      {:ok, _invite_code} ->
        conn
        |> put_flash(:info, "Invite code created successfully.")
        |> redirect(to: ~p"/pripyat/invite-codes")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new_invite_code, changeset: changeset)
    end
  end

  def edit(conn, %{"id" => id}) do
    invite_code = Accounts.get_invite_code(id)
    changeset = Accounts.change_invite_code(invite_code)
    render(conn, :edit_invite_code, invite_code: invite_code, changeset: changeset)
  end

  def update(conn, %{"id" => id, "invite_code" => invite_code_params}) do
    invite_code = Accounts.get_invite_code(id)

    case Accounts.update_invite_code(invite_code, invite_code_params) do
      {:ok, _invite_code} ->
        conn
        |> put_flash(:info, "Invite code updated successfully.")
        |> redirect(to: ~p"/pripyat/invite-codes")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit_invite_code, invite_code: invite_code, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    invite_code = Accounts.get_invite_code(id)
    {:ok, _invite_code} = Accounts.delete_invite_code(invite_code)

    conn
    |> put_flash(:info, "Invite code deleted successfully.")
    |> redirect(to: ~p"/pripyat/invite-codes")
  end

  def toggle_system(conn, %{"enabled" => enabled}) do
    enabled_bool = enabled == "true"

    case Elektrine.System.set_invite_codes_enabled(enabled_bool) do
      {:ok, _config} ->
        message =
          if enabled_bool do
            "Invite code system enabled. New user registrations now require invite codes."
          else
            "Invite code system disabled. Users can now register without invite codes."
          end

        conn
        |> put_flash(:info, message)
        |> redirect(to: ~p"/pripyat/invite-codes")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to update invite code system setting.")
        |> redirect(to: ~p"/pripyat/invite-codes")
    end
  end
end
