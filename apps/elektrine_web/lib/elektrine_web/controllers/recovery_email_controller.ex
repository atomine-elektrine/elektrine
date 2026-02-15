defmodule ElektrineWeb.RecoveryEmailController do
  use ElektrineWeb, :controller

  alias Elektrine.Accounts.RecoveryEmailVerification

  @doc """
  Verifies the recovery email token and lifts the restriction.
  Called when user clicks the verification link in their email.
  """
  def verify(conn, %{"token" => token}) do
    # First check if user was restricted before verification
    was_restricted =
      case RecoveryEmailVerification.get_user_by_token(token) do
        nil -> false
        user -> user.email_sending_restricted == true
      end

    case RecoveryEmailVerification.verify_token(token) do
      {:ok, _user} ->
        flash_message =
          if was_restricted do
            "Your recovery email has been verified and email sending has been restored."
          else
            "Your recovery email has been verified successfully."
          end

        conn
        |> put_flash(:info, flash_message)
        |> render(:success, was_restricted: was_restricted)

      {:error, :invalid_token} ->
        conn
        |> put_flash(:error, "Invalid or expired verification link.")
        |> render(:error, reason: :invalid_token)

      {:error, :token_expired} ->
        conn
        |> put_flash(
          :error,
          "This verification link has expired. Please request a new one from your account settings."
        )
        |> render(:error, reason: :token_expired)
    end
  end

  def verify(conn, _params) do
    conn
    |> put_flash(:error, "Invalid verification link.")
    |> render(:error, reason: :invalid_token)
  end
end
