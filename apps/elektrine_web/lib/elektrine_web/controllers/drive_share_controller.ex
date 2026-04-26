defmodule ElektrineWeb.DriveShareController do
  use ElektrineWeb, :controller

  alias Elektrine.Auth.RateLimiter
  alias Elektrine.Drive
  alias ElektrineWeb.ClientIP

  def show(conn, %{"token" => token}) do
    with %Drive.FileShare{} = share <- Drive.get_active_share(token),
         true <- Drive.share_owner_can_access?(share),
         true <- password_authorized?(conn, share),
         :ok <- Drive.reserve_share_download(share),
         %Drive.StoredFile{} = file <- share.stored_file,
         {:ok, binary} <- Drive.read_file(file) do
      deliver_share(conn, share, file, binary)
    else
      false -> render_password_prompt(conn, token)
      nil -> send_resp(conn, 404, "Not found")
      {:error, _reason} -> send_resp(conn, 404, "Not found")
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def authorize(conn, %{"token" => token, "password" => password}) do
    case Drive.get_active_share(token) do
      %Drive.FileShare{} = share ->
        if Drive.share_owner_can_access?(share) do
          rate_limit_key = share_rate_limit_key(conn, token)

          case RateLimiter.check_rate_limit(rate_limit_key) do
            {:ok, :allowed} ->
              if Drive.verify_share_password(share, password) do
                RateLimiter.record_successful_attempt(rate_limit_key)

                conn
                |> put_session("drive_share_access", grant_token_access(conn, token))
                |> redirect(to: ~p"/drive/share/#{token}")
              else
                RateLimiter.record_failed_attempt(rate_limit_key)
                render_password_prompt(conn, token, 401, "Password was incorrect")
              end

            {:error, {:rate_limited, retry_after, _reason}} ->
              render_password_prompt(
                conn,
                token,
                429,
                "Too many attempts. Try again in #{retry_after} seconds."
              )
          end
        else
          send_resp(conn, 404, "Not found")
        end

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end

  defp deliver_share(conn, share, file, binary) do
    conn =
      conn
      |> put_resp_header("cache-control", share_cache_control(share))
      |> put_resp_header("x-content-type-options", "nosniff")

    if Drive.share_inline_view?(share) do
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
    not Drive.share_requires_password?(share) or
      share.token in get_session(conn, "drive_share_access", [])
  end

  defp grant_token_access(conn, token) do
    (get_session(conn, "drive_share_access", []) ++ [token]) |> Enum.uniq()
  end

  defp share_rate_limit_key(conn, token) do
    "drive_share:" <> token <> ":" <> ClientIP.rate_limit_ip(conn)
  end

  defp share_cache_control(share) do
    if Drive.share_requires_password?(share) do
      "private, no-store"
    else
      "public, max-age=300"
    end
  end

  defp render_password_prompt(conn, token, status \\ 200, error_message \\ nil) do
    csrf_token = Plug.CSRFProtection.get_csrf_token()
    page_bg = Elektrine.Theme.default_value("color_base_100")
    text_color = Elektrine.Theme.default_value("color_base_content")
    card_bg = Elektrine.Theme.rgba(Elektrine.Theme.default_value("color_base_200"), 0.92)
    card_border = Elektrine.Theme.rgba(Elektrine.Theme.inverse_text_color(), 0.08)
    card_shadow = Elektrine.Theme.rgba(Elektrine.Theme.dark_text_color(), 0.35)
    input_border = Elektrine.Theme.rgba(Elektrine.Theme.inverse_text_color(), 0.12)
    input_bg = Elektrine.Theme.default_value("color_base_200")
    button_from = Elektrine.Theme.default_value("color_primary")
    button_to = Elektrine.Theme.default_value("color_accent")
    button_text = Elektrine.Theme.inverse_text_color()
    error_color = Elektrine.Theme.rgba(Elektrine.Theme.default_value("color_error"), 0.75)

    body = """
    <!DOCTYPE html>
    <html lang=\"en\">
      <head>
        <meta charset=\"utf-8\" />
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
        <title>Protected Share</title>
        <style>
          body { font-family: Inter, system-ui, sans-serif; background: #{page_bg}; color: #{text_color}; margin: 0; min-height: 100vh; display: grid; place-items: center; }
          .card { width: min(28rem, calc(100vw - 2rem)); background: #{card_bg}; border: 1px solid #{card_border}; border-radius: 1.5rem; padding: 2rem; box-shadow: 0 20px 60px #{card_shadow}; }
          h1 { margin: 0 0 0.5rem; font-size: 1.5rem; }
          p { color: #{text_color}; line-height: 1.6; opacity: 0.84; }
          input { width: 100%; margin-top: 1rem; border-radius: 0.9rem; border: 1px solid #{input_border}; background: #{input_bg}; color: #{text_color}; padding: 0.9rem 1rem; box-sizing: border-box; }
          button { margin-top: 1rem; width: 100%; border: 0; border-radius: 0.9rem; background: linear-gradient(135deg, #{button_from}, #{button_to}); color: #{button_text}; padding: 0.9rem 1rem; font-weight: 600; cursor: pointer; }
          .error { color: #{error_color}; margin-top: 0.75rem; }
        </style>
      </head>
      <body>
        <main class=\"card\">
          <h1>Password Protected Link</h1>
          <p>Enter the share password to continue.</p>
          #{if error_message, do: "<p class=\"error\">#{Plug.HTML.html_escape(error_message)}</p>", else: ""}
          <form method=\"post\" action=\"/drive/share/#{token}\">
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
