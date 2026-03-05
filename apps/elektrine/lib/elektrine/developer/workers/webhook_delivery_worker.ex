defmodule Elektrine.Developer.WebhookDeliveryWorker do
  @moduledoc """
  Oban worker for outbound developer webhook deliveries.

  Retries transient failures and records delivery outcomes.
  """

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 5,
    priority: 2

  alias Elektrine.Developer

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}, attempt: attempt}) do
    case Developer.process_webhook_delivery(delivery_id, attempt) do
      {:ok, _status} ->
        :ok

      {:error, :not_found} ->
        # Delivery row may have been deleted; treat as no-op.
        :ok

      {:error, {:unsafe_url, _reason}} ->
        {:discard, :unsafe_url}

      {:error, :webhook_disabled} ->
        {:discard, :webhook_disabled}

      {:error, {:http_error, status}} when status >= 400 and status < 500 and status != 429 ->
        {:discard, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
