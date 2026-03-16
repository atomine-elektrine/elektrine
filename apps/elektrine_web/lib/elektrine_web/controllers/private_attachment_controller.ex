defmodule ElektrineWeb.PrivateAttachmentController do
  use ElektrineWeb, :controller

  alias Elektrine.Uploads

  def show(conn, %{"token" => token}) do
    with {:ok, key} <- Uploads.verify_private_attachment_token(token),
         {:ok, filepath} <- Uploads.private_attachment_local_path(key) do
      filename = sanitize_filename(Path.basename(filepath))
      content_type = MIME.from_path(filepath)

      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", ~s(inline; filename="#{filename}"))
      |> send_file(200, filepath)
    else
      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")

      {:error, _reason} ->
        send_resp(conn, 404, "Not found")
    end
  end

  defp sanitize_filename(filename) when is_binary(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[<>:"\/\\|?*\x00-\x1F]/, "_")
    |> String.slice(0, 255)
    |> case do
      "" -> "download"
      value -> value
    end
  end

  defp sanitize_filename(_), do: "download"
end
