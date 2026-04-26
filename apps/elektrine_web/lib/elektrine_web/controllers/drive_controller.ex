defmodule ElektrineWeb.DriveController do
  use ElektrineWeb, :controller

  alias Elektrine.Drive

  def download(conn, %{"id" => id}) do
    current_user = conn.assigns.current_user

    if Drive.user_can_access?(current_user) do
      with {file_id, ""} <- Integer.parse(id),
           %Drive.StoredFile{} = file <- Drive.get_file(current_user.id, file_id),
           {:ok, binary} <- Drive.read_file(file) do
        conn
        |> put_resp_header("cache-control", "private, max-age=300")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_download({:binary, binary},
          filename: file.original_filename,
          content_type: file.content_type
        )
      else
        :error -> send_resp(conn, 404, "Not found")
        nil -> send_resp(conn, 404, "Not found")
        {:error, _reason} -> send_resp(conn, 404, "Not found")
        _ -> send_resp(conn, 404, "Not found")
      end
    else
      send_resp(conn, 403, "Drive unlocks at trust level #{Drive.minimum_trust_level()}")
    end
  end

  def preview(conn, %{"id" => id}) do
    current_user = conn.assigns.current_user

    if Drive.user_can_access?(current_user) do
      with {file_id, ""} <- Integer.parse(id),
           %Drive.StoredFile{} = file <- Drive.get_file(current_user.id, file_id),
           true <- Drive.inline_viewable_content_type?(file.content_type),
           {:ok, binary} <- Drive.read_file(file) do
        conn
        |> put_resp_header("cache-control", "private, max-age=300")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_content_type(file.content_type)
        |> send_resp(200, binary)
      else
        false -> send_resp(conn, 404, "Not found")
        :error -> send_resp(conn, 404, "Not found")
        nil -> send_resp(conn, 404, "Not found")
        {:error, _reason} -> send_resp(conn, 404, "Not found")
        _ -> send_resp(conn, 404, "Not found")
      end
    else
      send_resp(conn, 403, "Drive unlocks at trust level #{Drive.minimum_trust_level()}")
    end
  end
end
