defmodule ElektrineWeb.API.WebhookController do
  @moduledoc """
  External API controller for developer webhook management.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Developer
  alias Elektrine.Developer.Webhook
  alias Elektrine.Developer.WebhookDelivery
  alias ElektrineWeb.API.Response

  action_fallback ElektrineWeb.FallbackController

  @default_limit 20
  @max_limit 100

  @doc """
  GET /api/ext/v1/webhooks
  """
  def index(conn, params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], @default_limit) |> min(@max_limit)

    webhooks = Developer.list_webhooks(user.id)
    deliveries = Developer.list_webhook_deliveries(user.id, limit: limit)

    Response.ok(
      conn,
      %{
        webhooks: Enum.map(webhooks, &format_webhook/1),
        deliveries: Enum.map(deliveries, &format_delivery/1)
      },
      %{pagination: %{limit: limit, total_count: length(deliveries)}}
    )
  end

  @doc """
  POST /api/ext/v1/webhooks
  """
  def create(conn, params) do
    user = conn.assigns.current_user
    attrs = webhook_payload(params)

    case Developer.create_webhook(user.id, attrs) do
      {:ok, webhook} ->
        Response.created(conn, %{
          webhook: format_webhook(webhook),
          secret: webhook.secret
        })

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  GET /api/ext/v1/webhooks/:id
  """
  def show(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], @default_limit) |> min(@max_limit)

    with {:ok, webhook_id} <- parse_id(id),
         %Webhook{} = webhook <- Developer.get_webhook(user.id, webhook_id) do
      deliveries =
        Developer.list_webhook_deliveries(user.id, webhook_id: webhook.id, limit: limit)

      Response.ok(
        conn,
        %{
          webhook: format_webhook(webhook),
          deliveries: Enum.map(deliveries, &format_delivery/1)
        },
        %{pagination: %{limit: limit, total_count: length(deliveries)}}
      )
    else
      :error ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid webhook id")

      nil ->
        Response.error(conn, :not_found, "not_found", "Webhook not found")
    end
  end

  @doc """
  DELETE /api/ext/v1/webhooks/:id
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, webhook_id} <- parse_id(id),
         {:ok, _webhook} <- Developer.delete_webhook(user.id, webhook_id) do
      Response.ok(conn, %{message: "Webhook deleted"})
    else
      :error ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid webhook id")

      {:error, :not_found} ->
        Response.error(conn, :not_found, "not_found", "Webhook not found")

      {:error, _reason} ->
        Response.error(conn, :unprocessable_entity, "delete_failed", "Failed to delete webhook")
    end
  end

  @doc """
  POST /api/ext/v1/webhooks/:id/test
  """
  def test(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, webhook_id} <- parse_id(id) do
      case Developer.test_webhook(user.id, webhook_id) do
        {:ok, status} ->
          Response.ok(conn, %{message: "Webhook test delivered", status: status})

        {:error, :not_found} ->
          Response.error(conn, :not_found, "not_found", "Webhook not found")

        {:error, {:http_error, status}} ->
          Response.error(
            conn,
            :unprocessable_entity,
            "http_error",
            "Webhook endpoint returned HTTP #{status}",
            %{status: status}
          )

        {:error, {:request_failed, reason}} ->
          Response.error(
            conn,
            :unprocessable_entity,
            "request_failed",
            "Webhook delivery request failed",
            inspect(reason)
          )

        {:error, {:unsafe_url, reason}} ->
          Response.error(
            conn,
            :unprocessable_entity,
            "unsafe_url",
            "Unsafe webhook URL",
            inspect(reason)
          )
      end
    else
      :error ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid webhook id")
    end
  end

  @doc """
  POST /api/ext/v1/webhooks/:id/rotate-secret
  """
  def rotate_secret(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with {:ok, webhook_id} <- parse_id(id),
         {:ok, webhook} <- Developer.rotate_webhook_secret(user.id, webhook_id) do
      Response.ok(conn, %{message: "Secret rotated", secret: webhook.secret})
    else
      :error ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid webhook id")

      {:error, :not_found} ->
        Response.error(conn, :not_found, "not_found", "Webhook not found")

      {:error, _reason} ->
        Response.error(conn, :unprocessable_entity, "rotate_failed", "Failed to rotate secret")
    end
  end

  @doc """
  GET /api/ext/v1/webhooks/:id/deliveries
  """
  def deliveries(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    limit = parse_positive_int(params["limit"], @default_limit) |> min(@max_limit)

    with {:ok, webhook_id} <- parse_id(id),
         %Webhook{} = webhook <- Developer.get_webhook(user.id, webhook_id) do
      deliveries =
        Developer.list_webhook_deliveries(user.id, webhook_id: webhook.id, limit: limit)

      Response.ok(
        conn,
        %{deliveries: Enum.map(deliveries, &format_delivery/1)},
        %{pagination: %{limit: limit, total_count: length(deliveries)}}
      )
    else
      :error ->
        Response.error(conn, :bad_request, "invalid_id", "Invalid webhook id")

      nil ->
        Response.error(conn, :not_found, "not_found", "Webhook not found")
    end
  end

  defp webhook_payload(params) do
    source = Map.get(params, "webhook", params)

    events =
      case Map.get(source, "events", []) do
        nil -> []
        values when is_list(values) -> values
        value when is_binary(value) -> [value]
        _ -> []
      end

    %{
      name: source["name"],
      url: source["url"],
      events: events,
      enabled: Map.get(source, "enabled", true)
    }
  end

  defp format_webhook(webhook) do
    %{
      id: webhook.id,
      name: webhook.name,
      url: webhook.url,
      events: webhook.events || [],
      enabled: webhook.enabled,
      secret_prefix: format_secret_prefix(webhook.secret),
      last_triggered_at: webhook.last_triggered_at,
      last_response_status: webhook.last_response_status,
      last_error: webhook.last_error,
      inserted_at: webhook.inserted_at,
      updated_at: webhook.updated_at
    }
  end

  defp format_delivery(%WebhookDelivery{} = delivery) do
    %{
      id: delivery.id,
      webhook_id: delivery.webhook_id,
      event: delivery.event,
      event_id: delivery.event_id,
      status: delivery.status,
      attempt_count: delivery.attempt_count,
      response_status: delivery.response_status,
      error: delivery.error,
      duration_ms: delivery.duration_ms,
      last_attempted_at: delivery.last_attempted_at,
      delivered_at: delivery.delivered_at,
      inserted_at: delivery.inserted_at
    }
  end

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  defp parse_positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_positive_int(_, default), do: default

  defp format_secret_prefix(secret) when is_binary(secret) do
    String.slice(secret, 0, min(8, String.length(secret)))
  end

  defp format_secret_prefix(_), do: nil
end
