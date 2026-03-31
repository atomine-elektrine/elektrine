defmodule ElektrineWeb.FileShareController do
  use ElektrineWeb, :controller

  alias Elektrine.Files

  def show(conn, %{"token" => token}) do
    with %Files.FileShare{} = share <- Files.get_active_share(token),
         true <- password_authorized?(conn, share),
         %Files.StoredFile{} = file <- share.stored_file,
         {:ok, binary} <- Files.read_file(file) do
      _ = Files.increment_share_download_count(share)

      deliver_share(conn, share, file, binary)
    else
      false -> render_password_prompt(conn, token)
      nil -> send_resp(conn, 404, "Not found")
      {:error, _reason} -> send_resp(conn, 404, "Not found")
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def authorize(conn, %{"token" => token, "password" => password}) do
    case Files.get_active_share(token) do
      %Files.FileShare{} = share ->
        if Files.verify_share_password(share, password) do
          conn
          |> put_session("file_share_access", grant_token_access(conn, token))
          |> redirect(to: ~p"/files/share/#{token}")
        else
          render_password_prompt(conn, token, 401, "Password was incorrect")
        end

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end

  defp deliver_share(conn, share, file, binary) do
    conn =
      conn
      |> put_resp_header("cache-control", "public, max-age=300")
      |> put_resp_header("x-content-type-options", "nosniff")

    if Files.share_inline_view?(share) do
      conn
      |> put_resp_content_type(file.content_type)
      |> send_resp(200, binary)
    else
      send_download(conn, {:binary, binary},
        filename: file.original_filename,
        content_type: file.content_type
      )
    end
  end

  defp password_authorized?(conn, share) do
    not Files.share_requires_password?(share) or
      share.token in get_session(conn, "file_share_access", [])
  end

  defp grant_token_access(conn, token) do
    (get_session(conn, "file_share_access", []) ++ [token]) |> Enum.uniq()
  end

  defp render_password_prompt(conn, token, status \\ 200, error_message \\ nil) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()

    body = """
    <!DOCTYPE html>
    <html lang=\"en\">
      <head>
        <meta charset=\"utf-8\" />
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
        <title>Protected Share</title>
        <style>
          body { font-family: Inter, system-ui, sans-serif; background: #111827; color: #f9fafb; margin: 0; min-height: 100vh; display: grid; place-items: center; }
          .card { width: min(28rem, calc(100vw - 2rem)); background: rgba(31, 41, 55, 0.92); border: 1px solid rgba(255,255,255,0.08); border-radius: 1.5rem; padding: 2rem; box-shadow: 0 20px 60px rgba(0,0,0,0.35); }
          h1 { margin: 0 0 0.5rem; font-size: 1.5rem; }
          p { color: #d1d5db; line-height: 1.6; }
          input { width: 100%; margin-top: 1rem; border-radius: 0.9rem; border: 1px solid rgba(255,255,255,0.12); background: #0f172a; color: white; padding: 0.9rem 1rem; box-sizing: border-box; }
          button { margin-top: 1rem; width: 100%; border: 0; border-radius: 0.9rem; background: linear-gradient(135deg, #2563eb, #7c3aed); color: white; padding: 0.9rem 1rem; font-weight: 600; cursor: pointer; }
          .error { color: #fca5a5; margin-top: 0.75rem; }
        </style>
      </head>
      <body>
        <main class=\"card\">
          <h1>Password Protected Link</h1>
          <p>Enter the share password to continue.</p>
          #{if error_message, do: "<p class=\"error\">#{Plug.HTML.html_escape(error_message)}</p>", else: ""}
          <form method=\"post\" action=\"/files/share/#{token}\">
            <input type=\"hidden\" name=\"_csrf_token\" value=\"#{csrf_token}\" />
            <input type=\"password\" name=\"password\" placeholder=\"Share password\" autocomplete=\"current-password\" />
            <button type=\"submit\">Open Link</button>
          </form>
        </main>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("html")
    |> send_resp(status, body)
  end
end
