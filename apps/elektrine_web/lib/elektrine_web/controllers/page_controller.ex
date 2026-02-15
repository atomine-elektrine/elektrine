defmodule ElektrineWeb.PageController do
  use ElektrineWeb, :controller

  # Development-only error page test routes
  if Mix.env() == :dev do
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
