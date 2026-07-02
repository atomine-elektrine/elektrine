defmodule ElektrineWeb.API.TwoFactorAuthenticationController do
  @moduledoc """
  Two-factor authentication management API.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Accounts
  alias Elektrine.Accounts.TwoFactor
  alias ElektrineWeb.Endpoint

  @setup_salt "api_two_factor_setup"
  @setup_max_age_seconds 600

  action_fallback ElektrineWeb.FallbackController

  def settings(conn, _params) do
    user = conn.assigns[:current_user] |> reload_user()

    json(conn, %{settings: settings_payload(user)})
  end

  def setup(conn, %{"method" => "totp"}) do
    user = conn.assigns[:current_user] |> reload_user()

    with {:ok, setup} <- Accounts.initiate_two_factor_setup(user) do
      setup_token =
        Phoenix.Token.sign(Endpoint, @setup_salt, %{
          user_id: user.id,
          secret: setup.secret,
          hashed_backup_codes: setup.hashed_backup_codes
        })

      json(conn, %{
        method: "totp",
        setup_token: setup_token,
        provisioning_uri: setup.provisioning_uri,
        key: TwoFactor.secret_to_base32(setup.secret),
        backup_codes: setup.plain_backup_codes
      })
    end
  end

  def setup(conn, _params), do: invalid_method(conn)

  def confirm(conn, %{"method" => "totp", "password" => password, "code" => code} = params) do
    user = conn.assigns[:current_user] |> reload_user()

    with {:ok, setup} <- verify_setup_token(user.id, params["setup_token"]),
         {:ok, _verified_user} <- Accounts.verify_user_password(user, password),
         {:ok, updated_user} <-
           Accounts.enable_two_factor(user, setup.secret, setup.hashed_backup_codes, code) do
      json(conn, %{settings: settings_payload(updated_user)})
    else
      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Password is incorrect"})

      {:error, :invalid_totp_code} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid authentication code"})

      {:error, :invalid_setup_token} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid setup token"})

      {:error, :expired_setup_token} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Setup token has expired"})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to enable two-factor authentication"})
    end
  end

  def confirm(conn, %{"method" => "totp"}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "password, code, and setup_token are required"})
  end

  def confirm(conn, _params), do: invalid_method(conn)

  def backup_codes(conn, _params) do
    user = conn.assigns[:current_user] |> reload_user()

    case Accounts.regenerate_backup_codes(user) do
      {:ok, {updated_user, codes}} ->
        json(conn, %{backup_codes: codes, settings: settings_payload(updated_user)})

      {:error, :two_factor_not_enabled} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Two-factor authentication is not enabled"})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to regenerate backup codes"})
    end
  end

  def disable(conn, %{"method" => "totp", "password" => password}) do
    user = conn.assigns[:current_user] |> reload_user()

    with {:ok, _verified_user} <- Accounts.verify_user_password(user, password),
         {:ok, updated_user} <- Accounts.disable_two_factor(user) do
      json(conn, %{settings: settings_payload(updated_user)})
    else
      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Password is incorrect"})

      {:error, _reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to disable two-factor authentication"})
    end
  end

  def disable(conn, %{"method" => "totp"}) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "password is required"})
  end

  def disable(conn, _params), do: invalid_method(conn)

  defp verify_setup_token(user_id, token) when is_binary(token) do
    case Phoenix.Token.verify(Endpoint, @setup_salt, token, max_age: @setup_max_age_seconds) do
      {:ok, %{user_id: ^user_id, secret: secret, hashed_backup_codes: hashed_backup_codes}} ->
        {:ok, %{secret: secret, hashed_backup_codes: hashed_backup_codes}}

      {:ok, _other_user} ->
        {:error, :invalid_setup_token}

      {:error, :expired} ->
        {:error, :expired_setup_token}

      {:error, _reason} ->
        {:error, :invalid_setup_token}
    end
  end

  defp verify_setup_token(_user_id, _token), do: {:error, :invalid_setup_token}

  defp settings_payload(user) do
    %{
      enabled: user.two_factor_enabled == true,
      totp: %{
        enabled: user.two_factor_enabled == true,
        confirmed: user.two_factor_enabled == true
      },
      backup_codes: length(user.two_factor_backup_codes || [])
    }
  end

  defp reload_user(user), do: Accounts.get_user!(user.id)

  defp invalid_method(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "undefined mfa method"})
  end
end
