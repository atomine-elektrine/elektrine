defmodule ElektrineWeb.StripeWebhookController do
  @moduledoc """
  Handles Stripe webhook events for subscription management.
  """
  use ElektrineWeb, :controller

  require Logger

  alias Elektrine.Subscriptions

  @doc """
  Process incoming Stripe webhook events.

  Verifies the webhook signature and processes subscription-related events.
  """
  def webhook(conn, _params) do
    raw_body = conn.assigns[:raw_body] || conn.private[:cached_body]
    signature = get_stripe_signature(conn)
    signing_secret = get_signing_secret()

    with {:ok, _} <- validate_raw_body(raw_body),
         {:ok, _} <- validate_signature(signature),
         {:ok, _} <- validate_signing_secret(signing_secret),
         {:ok, event} <- construct_event(raw_body, signature, signing_secret),
         {:ok, _result} <- Subscriptions.process_webhook_event(event) do
      json(conn, %{received: true})
    else
      {:error, :no_raw_body} ->
        Logger.warning("Stripe webhook: missing raw body")

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Missing request body"})

      {:error, :no_signature} ->
        Logger.warning("Stripe webhook: missing signature")

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Missing Stripe-Signature header"})

      {:error, :no_signing_secret} ->
        Logger.error("Stripe webhook: signing secret not configured")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Webhook not configured"})

      {:error, %Stripe.Error{message: message}} ->
        Logger.warning("Stripe webhook signature verification failed: #{message}")

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid signature"})

      {:error, reason} ->
        Logger.error("Stripe webhook error: #{inspect(reason)}")

        conn
        |> put_status(:bad_request)
        |> json(%{error: "Webhook processing failed"})
    end
  end

  defp get_stripe_signature(conn) do
    case Plug.Conn.get_req_header(conn, "stripe-signature") do
      [signature | _] -> signature
      [] -> nil
    end
  end

  defp get_signing_secret do
    Application.get_env(:stripity_stripe, :signing_secret)
  end

  defp validate_raw_body(nil), do: {:error, :no_raw_body}
  defp validate_raw_body(""), do: {:error, :no_raw_body}
  defp validate_raw_body(body) when is_binary(body), do: {:ok, body}

  defp validate_signature(nil), do: {:error, :no_signature}
  defp validate_signature(""), do: {:error, :no_signature}
  defp validate_signature(sig) when is_binary(sig), do: {:ok, sig}

  defp validate_signing_secret(nil), do: {:error, :no_signing_secret}
  defp validate_signing_secret(""), do: {:error, :no_signing_secret}
  defp validate_signing_secret(secret) when is_binary(secret), do: {:ok, secret}

  defp construct_event(raw_body, signature, signing_secret) do
    Stripe.Webhook.construct_event(raw_body, signature, signing_secret)
  end
end
