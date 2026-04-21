defmodule ElektrineWeb.NoteShareController do
  use ElektrineWeb, :controller

  alias Elektrine.Notes

  def show(conn, %{"token" => token}) do
    case Notes.get_public_share(token) do
      %Notes.NoteShare{note: note} = share ->
        _ = Notes.increment_share_view_count(share)

        conn
        |> put_root_layout(html: false)
        |> put_resp_header("cache-control", "public, max-age=300")
        |> render(:show, note: note, page_title: public_title(note))

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end

  defp public_title(%{title: title, body: body}) do
    cond do
      is_binary(title) and title != "" -> title
      is_binary(body) and body != "" -> String.slice(body, 0, 48)
      true -> "Shared Note"
    end
  end
end
