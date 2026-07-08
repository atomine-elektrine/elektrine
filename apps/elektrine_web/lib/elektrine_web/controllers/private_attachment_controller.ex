defmodule ElektrineWeb.PrivateAttachmentController do
  use ElektrineWeb, :controller

  alias Elektrine.Uploads

  def show(conn, %{"token" => token}) do
    with {:ok, key} <- Uploads.verify_private_attachment_token(token),
         %{id: user_id} <- conn.assigns[:current_user],
         true <- Uploads.private_attachment_accessible_by_user?(key, user_id),
         {:ok, attachment} <- Uploads.private_attachment_content(key) do
      filename = sanitize_filename(Map.get(attachment, :filename))
      content_type = Map.get(attachment, :content_type, "application/octet-stream")
      body = Map.fetch!(attachment, :body)

      conn =
        conn
        |> put_resp_header("cache-control", "private, max-age=3600")
        |> put_resp_header("x-content-type-options", "nosniff")

      if inline_safe_content_type?(content_type) do
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("content-disposition", ~s(inline; filename="#{filename}"))
        |> send_resp(200, body)
      else
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, body)
      end
    else
      {:error, :not_found} ->
        send_resp(conn, 404, "Not found")

      {:error, _reason} ->
        send_resp(conn, 404, "Not found")

      _ ->
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

  defp inline_safe_content_type?(content_type) when is_binary(content_type) do
    normalized =
      content_type
      |> String.downcase()
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()

    cond do
      normalized in [
        "text/html",
        "application/xhtml+xml",
        "image/svg+xml",
        "image/svg+xml-compressed",
        "text/xml",
        "application/xml"
      ] ->
        false

      String.starts_with?(normalized, ["image/", "video/", "audio/"]) ->
        true

      normalized in ["application/pdf", "text/plain"] ->
        true

      true ->
        false
    end
  end
end
