defmodule ElektrineWeb.RegistrationPaymentController do
  use ElektrineWeb, :controller

  alias Elektrine.Subscriptions
  alias Elektrine.Subscriptions.Product

  def create(conn, _params) do
    with %Product{} = product <- Subscriptions.get_active_registration_product(),
         true <- Product.has_one_time?(product),
         {:ok, %{url: checkout_url}} <-
           Subscriptions.create_registration_checkout_session(product) do
      redirect(conn, external: checkout_url)
    else
      _ ->
        conn
        |> put_flash(:error, "Registration payment is not available right now.")
        |> redirect(to: ~p"/register")
    end
  end

  def show(conn, %{"checkout_session_id" => session_id, "access" => access}) do
    case Subscriptions.get_registration_checkout(session_id, access) do
      nil ->
        render_checkout(conn, nil)

      _checkout ->
        conn
        |> put_session(:registration_access_token, access)
        |> redirect(to: ~p"/register/purchase/success?checkout_session_id=#{session_id}")
    end
  end

  def show(conn, %{"checkout_session_id" => session_id}) do
    checkout =
      case get_session(conn, :registration_access_token) do
        token when is_binary(token) -> Subscriptions.get_registration_checkout(session_id, token)
        _ -> nil
      end

    render_checkout(conn, checkout)
  end

  def show(conn, _params) do
    conn
    |> put_flash(:error, "Missing registration payment details.")
    |> redirect(to: ~p"/register")
  end

  defp render_checkout(conn, checkout) do
    render(conn, :show,
      page_title: "Registration Payment",
      checkout: checkout,
      invite_code: checkout && checkout.invite_code,
      pending: is_nil(checkout) or checkout.status != "fulfilled"
    )
  end
end
