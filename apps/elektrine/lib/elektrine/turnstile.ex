defmodule Elektrine.Turnstile do
  @moduledoc """
  Cloudflare Turnstile verification functionality.
  """

  require Logger

  @doc """
  Verifies a Turnstile response token with the Cloudflare Turnstile service.

  ## Parameters

    * `token` - The Turnstile response token from the frontend
    * `remote_ip` - The user's IP address (optional)

  ## Returns

    * `{:ok, :verified}` - If the captcha is valid
    * `{:error, reason}` - If the captcha is invalid or verification failed

  """
  def verify(token, remote_ip \\ nil) do
    config = Application.get_env(:elektrine, :turnstile) || []
    secret_key = Keyword.get(config, :secret_key)
    verify_url = Keyword.get(config, :verify_url)
    skip_verification = Keyword.get(config, :skip_verification, false)

    # Log for debugging
    Logger.debug("Turnstile config: skip_verification=#{skip_verification}")

    cond do
      # Allow skipping verification if configured (for dev/test environments)
      skip_verification == true ->
        Logger.debug("Turnstile: skipping verification (dev/test mode)")
        {:ok, :verified}

      # Check for missing or empty token early
      is_nil(token) or token == "" ->
        Logger.warning("Turnstile verification failed: missing or empty token")
        {:error, :missing_token}

      is_nil(secret_key) ->
        Logger.error("Turnstile secret key not configured")
        {:error, :missing_secret_key}

      true ->
        body = build_verification_body(secret_key, token, remote_ip)

        headers = [{"content-type", "application/x-www-form-urlencoded"}]
        request = Finch.build(:post, verify_url, headers, body)

        case Finch.request(request, Elektrine.Finch) do
          {:ok, %Finch.Response{status: 200, body: response_body}} ->
            handle_response(response_body)

          {:ok, %Finch.Response{status: status_code}} ->
            Logger.error("Turnstile API HTTP error: #{status_code}")
            {:error, {:http_error, status_code}}

          {:error, reason} ->
            Logger.error("Turnstile API network error: #{inspect(reason)}")
            {:error, {:network_error, reason}}
        end
    end
  end

  defp build_verification_body(secret_key, token, remote_ip) do
    params = [
      {"secret", secret_key},
      {"response", token}
    ]

    params =
      case remote_ip do
        nil -> params
        ip -> [{"remoteip", ip} | params]
      end

    URI.encode_query(params)
  end

  defp handle_response(response_body) do
    case Jason.decode(response_body) do
      {:ok, %{"success" => true}} ->
        {:ok, :verified}

      {:ok, %{"success" => false, "error-codes" => error_codes}} ->
        Logger.error("Turnstile verification failed with error codes: #{inspect(error_codes)}")
        {:error, {:verification_failed, error_codes}}

      {:ok, %{"success" => false}} ->
        {:error, :verification_failed}

      {:error, _} ->
        {:error, :invalid_response}
    end
  end
end
