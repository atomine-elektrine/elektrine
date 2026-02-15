defmodule ElektrineWeb.CaptchaController do
  use ElektrineWeb, :controller

  alias Elektrine.Captcha

  @doc """
  Generates and serves a captcha image.
  Stores the token in session for later verification.
  """
  def show(conn, _params) do
    {image_binary, _answer, token} = Captcha.generate()

    conn
    |> put_session(:captcha_token, token)
    |> put_resp_content_type("image/png")
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate")
    |> put_resp_header("pragma", "no-cache")
    |> send_resp(200, image_binary)
  end
end
