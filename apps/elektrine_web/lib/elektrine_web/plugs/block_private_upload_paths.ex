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

  def call(%Plug.Conn{request_path: path} = conn, _opts) when is_binary(path) do
    if Enum.any?(@private_prefixes, &String.starts_with?(path, &1)) do
      conn
      |> send_resp(404, "Not found")
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn
end
