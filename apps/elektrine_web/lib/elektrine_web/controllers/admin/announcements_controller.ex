defmodule ElektrineWeb.Admin.AnnouncementsController do
  use ElektrineWeb, :controller

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}

  def index(conn, _params) do
    announcements = Elektrine.Admin.list_announcements()
    current_user = conn.assigns.current_user
    timezone = current_user.timezone || "UTC"
    time_format = current_user.time_format || "12"

    render(conn, :announcements,
      announcements: announcements,
      timezone: timezone,
      time_format: time_format
    )
  end

  def new(conn, _params) do
    changeset = Elektrine.Admin.change_announcement(%Elektrine.Admin.Announcement{})
    render(conn, :new_announcement, changeset: changeset)
  end

  def create(conn, %{"announcement" => announcement_params}) do
    current_user = conn.assigns.current_user
    announcement_params = Map.put(announcement_params, "created_by_id", current_user.id)

    case Elektrine.Admin.create_announcement(announcement_params) do
      {:ok, _announcement} ->
        conn
        |> put_flash(:info, "Announcement created successfully.")
        |> redirect(to: ~p"/pripyat/announcements")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new_announcement, changeset: changeset)
    end
  end

  def edit(conn, %{"id" => id}) do
    announcement = Elektrine.Admin.get_announcement!(id)
    changeset = Elektrine.Admin.change_announcement(announcement)
    render(conn, :edit_announcement, announcement: announcement, changeset: changeset)
  end

  def update(conn, %{"id" => id, "announcement" => announcement_params}) do
    announcement = Elektrine.Admin.get_announcement!(id)

    case Elektrine.Admin.update_announcement(announcement, announcement_params) do
      {:ok, _announcement} ->
        conn
        |> put_flash(:info, "Announcement updated successfully.")
        |> redirect(to: ~p"/pripyat/announcements")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit_announcement, announcement: announcement, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    announcement = Elektrine.Admin.get_announcement!(id)

    case Elektrine.Admin.delete_announcement(announcement) do
      {:ok, _announcement} ->
        conn
        |> put_flash(:info, "Announcement deleted successfully.")
        |> redirect(to: ~p"/pripyat/announcements")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Unable to delete announcement.")
        |> redirect(to: ~p"/pripyat/announcements")
    end
  end
end
