defmodule ElektrineWeb.AdminUpdatesController do
  use ElektrineWeb, :controller

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}

  def index(conn, _params) do
    updates = Elektrine.Updates.get_all_updates()
    render(conn, :index, updates: updates)
  end

  def new(conn, _params) do
    render(conn, :new)
  end

  def create(conn, %{"update" => update_params}) do
    badge = if update_params["badge"] != "", do: update_params["badge"], else: nil

    items =
      update_params["items"]
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    attrs = %{
      title: update_params["title"],
      description: update_params["description"],
      badge: badge,
      items: items,
      created_by_id: conn.assigns.current_user.id
    }

    case Elektrine.Updates.create_update(attrs) do
      {:ok, _update} ->
        conn
        |> put_flash(:info, "Update created successfully and will appear on the homepage.")
        |> redirect(to: ~p"/pripyat/updates")

      {:error, changeset} ->
        render(conn, :new, changeset: changeset)
    end
  end

  def delete(conn, %{"id" => id}) do
    update = Elektrine.Updates.get_update!(id)

    case Elektrine.Updates.delete_update(update) do
      {:ok, _update} ->
        conn
        |> put_flash(:info, "Update deleted successfully.")
        |> redirect(to: ~p"/pripyat/updates")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to delete update.")
        |> redirect(to: ~p"/pripyat/updates")
    end
  end
end
