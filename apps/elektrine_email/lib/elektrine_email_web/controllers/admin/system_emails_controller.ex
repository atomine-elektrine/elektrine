defmodule ElektrineEmailWeb.Admin.SystemEmailsController do
  @moduledoc false

  use ElektrineEmailWeb, :controller

  alias Elektrine.Email

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}
  plug :assign_timezone_and_format

  defp assign_timezone_and_format(conn, _opts) do
    current_user = conn.assigns[:current_user]

    conn
    |> assign(:timezone, (current_user && current_user.timezone) || "Etc/UTC")
    |> assign(:time_format, (current_user && current_user.time_format) || "12")
  end

  def new(conn, _params) do
    render_new(conn, %{})
  end

  def create(conn, %{"system_email" => params}) do
    current_user = conn.assigns.current_user

    case Email.enqueue_system_email_to_all_users(params, admin_user_id: current_user.id) do
      {:ok, _job} ->
        conn
        |> put_flash(:info, "System email queued for delivery to all user mailboxes.")
        |> redirect(to: ~p"/pripyat/system-email")

      {:error, reason} ->
        conn
        |> put_flash(:error, error_message(reason))
        |> render_new(params)
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Enter a subject and message body.")
    |> render_new(%{})
  end

  defp render_new(conn, params) do
    render(conn, :new,
      params: params,
      from_address: Email.system_email_from_address()
    )
  end

  defp error_message(:missing_subject), do: "Enter a subject."
  defp error_message(:missing_body), do: "Enter a message body."
  defp error_message(:missing_required_fields), do: "Enter a subject and message body."
  defp error_message(_reason), do: "Unable to queue system email."
end
