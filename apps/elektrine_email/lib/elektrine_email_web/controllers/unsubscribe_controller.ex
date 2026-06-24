defmodule ElektrineEmailWeb.UnsubscribeController do
  use ElektrineEmailWeb, :controller
  alias Elektrine.Email.Unsubscribes

  require Logger

  @doc """
  RFC 8058 one-click unsubscribe endpoint (POST).
  This is called automatically by email clients when users click "Unsubscribe".
  """
  def one_click(conn, %{"token" => token}) do
    with {:ok, info} <- get_unsubscribe_info(token),
         {:ok, _} <- record_unsubscribe(info, conn) do
      # RFC 8058 requires returning 200 OK
      conn
      |> put_status(:ok)
      |> text("Unsubscribed successfully")
    else
      {:error, :invalid_token} ->
        conn
        |> put_status(:bad_request)
        |> text("Invalid unsubscribe token")

      {:error, reason} ->
        Logger.error("Unsubscribe failed: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> text("Unsubscribe failed")
    end
  end

  @doc """
  Traditional unsubscribe page (GET).
  Shows a confirmation page for users who click the link in the email body.
  """
  def show(conn, %{"token" => token}) do
    case get_unsubscribe_info(token) do
      {:ok, info} ->
        render(conn, :show, token: token, email: info.email, list_id: info.list_id)

      {:error, :invalid_token} ->
        conn
        |> put_flash(:error, "Invalid or expired unsubscribe link")
        |> redirect(to: ~p"/")
    end
  end

  @doc """
  Processes the traditional unsubscribe form submission (POST from web page).
  """
  def confirm(conn, %{"token" => token}) do
    with {:ok, info} <- get_unsubscribe_info(token),
         {:ok, _} <- record_unsubscribe(info, conn) do
      conn
      |> put_flash(:info, "You have been unsubscribed successfully")
      |> render(:confirmed, email: info.email)
    else
      {:error, :invalid_token} ->
        conn
        |> put_flash(:error, "Invalid or expired unsubscribe link")
        |> redirect(to: ~p"/")

      {:error, reason} ->
        Logger.error("Unsubscribe confirmation failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Failed to unsubscribe. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  @doc """
  Resubscribe endpoint.
  """
  def resubscribe(conn, %{"email" => email, "list_id" => list_id}) do
    {:ok, _count} = Unsubscribes.resubscribe(email, list_id)

    conn
    |> put_flash(:info, "You have been resubscribed successfully")
    |> render(:resubscribed, email: email)
  end

  # Private helper functions

  defp get_unsubscribe_info(token) do
    Unsubscribes.verify_token(token)
  end

  defp record_unsubscribe(info, conn) do
    opts = [
      list_id: info.list_id,
      token: info.token || Unsubscribes.generate_token(info.email, info.list_id),
      ip_address: get_ip_address(conn),
      user_agent: get_user_agent(conn)
    ]

    Unsubscribes.unsubscribe(info.email, opts)
  end

  defp get_ip_address(conn) do
    ElektrineWeb.ClientIP.client_ip(conn)
  end

  defp get_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      [] -> nil
    end
  end
end
