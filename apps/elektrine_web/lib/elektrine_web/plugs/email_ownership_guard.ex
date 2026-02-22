defmodule ElektrineWeb.Plugs.EmailOwnershipGuard do
  @moduledoc """
  Plug to ensure users can only access emails and mailboxes they own.
  Prevents unauthorized access to other users' emails.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]
  require Logger

  def init(opts), do: opts

  def call(conn, opts) do
    action = opts[:action] || :check_message_access

    case action do
      :check_message_access -> check_message_access(conn)
      :check_mailbox_access -> check_mailbox_access(conn)
      _ -> conn
    end
  end

  # Validate message access
  defp check_message_access(conn) do
    user_id =
      case conn.assigns[:current_user] do
        %{id: id} -> id
        _ -> nil
      end

    message_id = get_message_id_from_params(conn.params)

    cond do
      is_nil(user_id) ->
        # Not authenticated
        conn
        |> put_flash(:error, "You must be logged in to view emails")
        |> redirect(to: "/login")
        |> halt()

      is_nil(message_id) ->
        # No message ID in params, continue
        conn

      true ->
        validate_message_ownership(conn, message_id, user_id)
    end
  end

  # Validate mailbox access
  defp check_mailbox_access(conn) do
    user_id =
      case conn.assigns[:current_user] do
        %{id: id} -> id
        _ -> nil
      end

    if is_nil(user_id) do
      conn
      |> put_flash(:error, "You must be logged in to access mailboxes")
      |> redirect(to: "/login")
      |> halt()
    else
      conn
    end
  end

  # Validate user owns the message
  defp validate_message_ownership(conn, message_id, user_id) do
    case Elektrine.Email.get_user_message(message_id, user_id) do
      {:ok, _message} ->
        # Access granted
        conn

      {:error, :access_denied} ->
        Logger.warning("User #{user_id} attempted to access unauthorized message #{message_id}")

        conn
        |> put_status(:forbidden)
        |> put_flash(:error, "You don't have permission to view this email")
        |> redirect(to: "/email")
        |> halt()

      {:error, :message_not_found} ->
        conn
        |> put_status(:not_found)
        |> put_flash(:error, "Email not found")
        |> redirect(to: "/email")
        |> halt()

      {:error, reason} ->
        Logger.error(
          "Email access error for user #{user_id}, message #{message_id}: #{inspect(reason)}"
        )

        conn
        |> put_status(:internal_server_error)
        |> put_flash(:error, "Unable to access email")
        |> redirect(to: "/email")
        |> halt()
    end
  end

  # Extract message ID from params
  defp get_message_id_from_params(params) do
    cond do
      params["id"] -> String.to_integer(params["id"])
      params["message_id"] -> String.to_integer(params["message_id"])
      true -> nil
    end
  rescue
    _ -> nil
  end
end
