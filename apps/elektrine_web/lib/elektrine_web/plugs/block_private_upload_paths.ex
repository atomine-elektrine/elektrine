defmodule ElektrineWeb.Plugs.BlockPrivateUploadPaths do
  @moduledoc false

  import Plug.Conn

  @private_prefixes [
    "/uploads/chat-attachments/",
    "/uploads/attachments/",
    "/uploads/voice-messages/",
    "/uploads/email-attachments/",
    "/uploads/timeline-attachments/",
    "/uploads/discussion-attachments/",
    "/uploads/gallery-attachments/"
  ]

  def init(opts), do: opts

  def call(%Plug.Conn{} = conn, _opts) do
    path = normalized_path(conn)

    if Enum.any?(@private_prefixes, &String.starts_with?(path, &1)) do
      conn
      |> send_resp(404, "Not found")
      |> halt()
    else
      conn
    end
  end

  defp normalized_path(%Plug.Conn{path_info: segments}) when is_list(segments) do
    "/" <> Enum.join(segments, "/") <> "/"
  end

  defp normalized_path(%Plug.Conn{request_path: path}) when is_binary(path), do: path
end
