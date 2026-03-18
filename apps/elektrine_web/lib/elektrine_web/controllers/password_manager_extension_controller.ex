defmodule ElektrineWeb.PasswordManagerExtensionController do
  use ElektrineWeb, :controller

  @extension_dir Path.expand("../../../../../clients/password-manager-extension", __DIR__)

  def download(conn, %{"browser" => browser}) do
    with {:ok, filename, content_type} <- download_metadata(browser),
         {:ok, archive} <- build_archive() do
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"#{filename}\""
      )
      |> send_resp(200, archive)
    else
      :error ->
        send_resp(conn, 404, "Not found")

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> text("Failed to package browser extension: #{inspect(reason)}")
    end
  end

  defp download_metadata("chromium") do
    {:ok, "elektrine-vault-extension-chromium.zip", "application/zip"}
  end

  defp download_metadata("firefox") do
    {:ok, "elektrine-vault-extension-firefox.xpi", "application/x-xpinstall"}
  end

  defp download_metadata(_browser), do: :error

  defp build_archive do
    files =
      @extension_dir
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn path ->
        relative_path = Path.relative_to(path, @extension_dir)
        {String.to_charlist(relative_path), File.read!(path)}
      end)

    case :zip.create(~c"elektrine-vault-extension.zip", files, [:memory]) do
      {:ok, {_name, archive}} -> {:ok, archive}
      {:error, reason} -> {:error, reason}
    end
  end
end
