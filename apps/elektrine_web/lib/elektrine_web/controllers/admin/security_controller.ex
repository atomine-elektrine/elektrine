defmodule ElektrineWeb.Admin.SecurityController do
  @moduledoc """
  Passkey-backed security controls for admin elevation and per-action re-sign.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Accounts.Passkeys
  alias ElektrineWeb.AdminSecurity

  plug :put_layout, html: {ElektrineWeb.Layouts, :admin}

  def elevate(conn, params) do
    return_to = AdminSecurity.normalize_return_to(params["return_to"] || "/pripyat")
    has_passkeys = Passkeys.has_passkeys?(conn.assigns.current_user)

    render(conn, :elevate,
      return_to: return_to,
      has_passkeys: has_passkeys
    )
  end

  def start_elevation(conn, params) do
    user = conn.assigns.current_user

    with true <- Passkeys.has_passkeys?(user),
         {:ok, challenge_data} <-
           Passkeys.generate_authentication_challenge(user, host: conn.host) do
      intent_token = AdminSecurity.sign_elevation_intent(user, params["return_to"] || "/pripyat")

      json(conn, %{
        challenge_b64: challenge_data.challenge_b64,
        rp_id: challenge_data.rp_id,
        timeout: challenge_data.timeout,
        user_verification: challenge_data.user_verification,
        allow_credentials: challenge_data.allow_credentials,
        intent_token: intent_token
      })
    else
      false ->
        json_error(conn, :unprocessable_entity, "Admin passkey is required before elevation.")

      {:error, _reason} ->
        json_error(conn, :unprocessable_entity, "Unable to start passkey challenge.")
    end
  end

  def finish_elevation(conn, params) do
    user = conn.assigns.current_user

    with {:ok, return_to} <- AdminSecurity.verify_elevation_intent(user, params["intent_token"]),
         {:ok, assertion} <- decode_assertion(params["assertion"]),
         {:ok, challenge} <- fetch_challenge(params["challenge"]),
         {:ok, verified_user, credential} <-
           Passkeys.verify_authentication_with_credential(challenge, assertion),
         true <- verified_user.id == user.id do
      conn = AdminSecurity.refresh_after_passkey(conn, credential.credential_id)

      json(conn, %{
        ok: true,
        redirect_to: return_to
      })
    else
      {:error, :invalid_intent} ->
        json_error(conn, :unauthorized, "Elevation intent is invalid or expired.")

      {:error, :invalid_assertion} ->
        json_error(conn, :unprocessable_entity, "Invalid passkey assertion payload.")

      {:error, :challenge_expired} ->
        json_error(conn, :unauthorized, "Passkey challenge expired. Start again.")

      {:error, _reason} ->
        json_error(conn, :unauthorized, "Passkey verification failed.")

      false ->
        json_error(conn, :unauthorized, "Passkey verification did not match the current admin.")
    end
  end

  def start_action(conn, %{"method" => method, "path" => path}) do
    user = conn.assigns.current_user

    with :ok <- ensure_elevated(conn),
         {:ok, normalized_method, normalized_path} <-
           AdminSecurity.normalize_action_target(method, path),
         true <- Passkeys.has_passkeys?(user),
         {:ok, challenge_data} <-
           Passkeys.generate_authentication_challenge(user, host: conn.host) do
      intent_token = AdminSecurity.sign_action_intent(user, normalized_method, normalized_path)

      json(conn, %{
        challenge_b64: challenge_data.challenge_b64,
        rp_id: challenge_data.rp_id,
        timeout: challenge_data.timeout,
        user_verification: challenge_data.user_verification,
        allow_credentials: challenge_data.allow_credentials,
        intent_token: intent_token
      })
    else
      {:error, :elevation_required} ->
        json_error(conn, :unauthorized, "Admin elevation expired. Re-elevate and try again.")

      {:error, :invalid_action_target} ->
        json_error(conn, :unprocessable_entity, "Invalid admin action target.")

      false ->
        json_error(
          conn,
          :unprocessable_entity,
          "Admin passkey is required before action signing."
        )

      {:error, _reason} ->
        json_error(conn, :unprocessable_entity, "Unable to start passkey challenge.")
    end
  end

  def start_action(conn, _params) do
    json_error(conn, :unprocessable_entity, "Missing action metadata.")
  end

  def finish_action(conn, params) do
    user = conn.assigns.current_user

    with :ok <- ensure_elevated(conn),
         {:ok, method, path} <- AdminSecurity.verify_action_intent(user, params["intent_token"]),
         {:ok, assertion} <- decode_assertion(params["assertion"]),
         {:ok, challenge} <- fetch_challenge(params["challenge"]),
         {:ok, verified_user, credential} <-
           Passkeys.verify_authentication_with_credential(challenge, assertion),
         true <- verified_user.id == user.id do
      conn = AdminSecurity.refresh_after_passkey(conn, credential.credential_id)
      grant_token = AdminSecurity.issue_action_grant(conn, user, method, path)

      json(conn, %{
        grant_token: grant_token,
        expires_in: AdminSecurity.action_grant_ttl_seconds()
      })
    else
      {:error, :elevation_required} ->
        json_error(conn, :unauthorized, "Admin elevation expired. Re-elevate and try again.")

      {:error, :invalid_intent} ->
        json_error(conn, :unauthorized, "Action intent is invalid or expired.")

      {:error, :invalid_assertion} ->
        json_error(conn, :unprocessable_entity, "Invalid passkey assertion payload.")

      {:error, :challenge_expired} ->
        json_error(conn, :unauthorized, "Passkey challenge expired. Start again.")

      {:error, _reason} ->
        json_error(conn, :unauthorized, "Passkey verification failed.")

      false ->
        json_error(conn, :unauthorized, "Passkey verification did not match the current admin.")
    end
  end

  defp decode_assertion(assertion) when is_map(assertion), do: {:ok, assertion}

  defp decode_assertion(assertion_json) when is_binary(assertion_json) do
    case Jason.decode(assertion_json) do
      {:ok, assertion} when is_map(assertion) -> {:ok, assertion}
      _ -> {:error, :invalid_assertion}
    end
  end

  defp decode_assertion(_), do: {:error, :invalid_assertion}

  defp fetch_challenge(challenge_b64) when is_binary(challenge_b64) do
    with {:ok, challenge_bytes} <- Base.url_decode64(challenge_b64, padding: false),
         {:ok, challenge} <- Passkeys.get_challenge(challenge_bytes),
         true <- not is_nil(challenge) do
      {:ok, challenge}
    else
      _ -> {:error, :challenge_expired}
    end
  end

  defp fetch_challenge(_), do: {:error, :challenge_expired}

  defp ensure_elevated(conn) do
    now = System.system_time(:second)
    elevated_until = get_session(conn, :admin_elevated_until)

    if is_integer(elevated_until) and elevated_until >= now do
      :ok
    else
      {:error, :elevation_required}
    end
  end

  defp json_error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
