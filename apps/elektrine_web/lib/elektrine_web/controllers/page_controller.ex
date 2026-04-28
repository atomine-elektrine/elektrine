defmodule ElektrineWeb.PageController do
  use ElektrineWeb, :controller

  def canary(conn, _params) do
    canary = read_canary_file("current.md")

    render(conn, :canary,
      page_title: "Warrant Canary",
      canary: canary,
      canary_html: Elektrine.Markdown.to_html(canary),
      signature: read_canary_file("current.md.asc"),
      public_key: read_canary_file("canary-public-key.asc")
    )
  end

  def canary_current(conn, _params) do
    send_canary_file(conn, "current.md", "text/markdown; charset=utf-8")
  end

  def canary_signature(conn, _params) do
    send_canary_file(conn, "current.md.asc", "application/pgp-signature")
  end

  def canary_public_key(conn, _params) do
    send_canary_file(conn, "canary-public-key.asc", "application/pgp-keys")
  end

  defp read_canary_file(filename) do
    filename
    |> canary_path()
    |> File.read()
    |> case do
      {:ok, content} -> content
      {:error, _reason} -> nil
    end
  end

  defp send_canary_file(conn, filename, content_type) do
    path = canary_path(filename)

    if File.regular?(path) do
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("content-disposition", ~s(inline; filename="#{filename}"))
      |> send_file(200, path)
    else
      send_resp(conn, 404, "not found")
    end
  end

  defp canary_path(filename) do
    :elektrine_web
    |> :code.priv_dir()
    |> Path.join("canary")
    |> Path.join(filename)
  end

  # Development-only error page test routes
  if Application.compile_env(:elektrine, :dev_routes, false) do
    def flash_test_controller(conn, %{"kind" => kind}) do
      {flash_kind, message} =
        case kind do
          "error" -> {:error, "Controller error flash (dev test)"}
          _ -> {:info, "Controller info flash (dev test)"}
        end

      conn
      |> put_flash(flash_kind, message)
      |> redirect(to: ~p"/dev/flash-test")
    end

    def test_404(conn, _params) do
      conn
      |> put_status(404)
      |> put_view(ElektrineWeb.ErrorHTML)
      |> render(:"404")
    end

    def test_500(conn, _params) do
      conn
      |> put_status(500)
      |> put_view(ElektrineWeb.ErrorHTML)
      |> render(:"500")
    end

    def test_403(conn, _params) do
      conn
      |> put_status(403)
      |> put_view(ElektrineWeb.ErrorHTML)
      |> render(:"403")
    end

    def test_413(conn, _params) do
      conn
      |> put_status(413)
      |> put_view(ElektrineWeb.ErrorHTML)
      |> render(:"413")
    end
  end
end
