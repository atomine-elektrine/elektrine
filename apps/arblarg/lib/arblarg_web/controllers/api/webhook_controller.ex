defmodule ArblargWeb.API.WebhookController do
  @moduledoc """
  API controller for incoming chat webhooks.

  Management endpoints (list/create/update/rotate/deactivate/delete) run on
  the authenticated API surface and require the `manage_webhooks` permission
  on the target conversation.

  The execute endpoint (`POST /api/webhooks/:id/:token`) is unauthenticated:
  the webhook token is the credential. Unknown ids and bad tokens both
  return 404 to avoid oracle behavior.
  """
  use ArblargWeb, :controller

  alias Elektrine.Messaging

  action_fallback ElektrineWeb.FallbackController

  @doc """
  GET /api/conversations/:conversation_id/webhooks
  Lists the webhooks of a conversation.
  """
  def index(conn, %{"conversation_id" => conversation_id}) do
    user = conn.assigns[:current_user]

    with_valid_id(conn, conversation_id, fn conv_id ->
      case Messaging.list_chat_webhooks(conv_id, user.id) do
        {:ok, webhooks} ->
          json(conn, %{webhooks: Enum.map(webhooks, &format_webhook/1)})

        {:error, reason} ->
          handle_error(conn, reason)
      end
    end)
  end

  @doc """
  POST /api/conversations/:conversation_id/webhooks
  Creates a webhook. The response includes the plaintext token exactly once.
  """
  def create(conn, %{"conversation_id" => conversation_id} = params) do
    user = conn.assigns[:current_user]

    with_valid_id(conn, conversation_id, fn conv_id ->
      attrs = %{
        "name" => params["name"],
        "avatar_url" => params["avatar_url"]
      }

      case Messaging.create_chat_webhook(conv_id, user.id, attrs) do
        {:ok, webhook} ->
          conn
          |> put_status(:created)
          |> json(%{webhook: format_webhook(webhook)})

        {:error, reason} ->
          handle_error(conn, reason)
      end
    end)
  end

  @doc """
  PUT /api/webhooks/:id
  Renames a webhook and/or updates its avatar.
  """
  def update(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with_valid_id(conn, id, fn webhook_id ->
      case Messaging.update_chat_webhook(webhook_id, user.id, params) do
        {:ok, webhook} ->
          json(conn, %{webhook: format_webhook(webhook)})

        {:error, reason} ->
          handle_error(conn, reason)
      end
    end)
  end

  @doc """
  POST /api/webhooks/:id/rotate
  Rotates a webhook token. The response includes the new plaintext token
  exactly once.
  """
  def rotate(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with_valid_id(conn, id, fn webhook_id ->
      case Messaging.rotate_chat_webhook_token(webhook_id, user.id) do
        {:ok, webhook} ->
          json(conn, %{webhook: format_webhook(webhook)})

        {:error, reason} ->
          handle_error(conn, reason)
      end
    end)
  end

  @doc """
  POST /api/webhooks/:id/deactivate
  Deactivates a webhook without deleting it.
  """
  def deactivate(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with_valid_id(conn, id, fn webhook_id ->
      case Messaging.deactivate_chat_webhook(webhook_id, user.id) do
        {:ok, webhook} ->
          json(conn, %{webhook: format_webhook(webhook)})

        {:error, reason} ->
          handle_error(conn, reason)
      end
    end)
  end

  @doc """
  DELETE /api/webhooks/:id
  Deletes a webhook.
  """
  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with_valid_id(conn, id, fn webhook_id ->
      case Messaging.delete_chat_webhook(webhook_id, user.id) do
        {:ok, _webhook} ->
          json(conn, %{success: true})

        {:error, reason} ->
          handle_error(conn, reason)
      end
    end)
  end

  @doc """
  POST /api/webhooks/:id/:token
  Executes a webhook: posts a message into the webhook's conversation.

  No session or API token required -- the webhook token is the credential.
  Body: {"content": "...", "username": optional, "avatar_url": optional}.
  """
  def execute(conn, %{"id" => id, "token" => token} = params) do
    case Messaging.execute_chat_webhook(id, token, params) do
      {:ok, message} ->
        conn
        |> put_status(:created)
        |> json(%{id: message.id, conversation_id: message.conversation_id})

      {:error, reason} ->
        handle_error(conn, reason)
    end
  end

  # Error mapping

  defp handle_error(conn, :not_found) do
    conn |> put_status(:not_found) |> json(%{error: "Not found"})
  end

  defp handle_error(conn, :unauthorized) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "You do not have permission to manage webhooks here"})
  end

  defp handle_error(conn, :unsupported_conversation) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Webhooks are only supported in channels and groups"})
  end

  defp handle_error(conn, :webhook_limit_reached) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Webhook limit reached for this conversation"})
  end

  defp handle_error(conn, :webhook_inactive) do
    conn |> put_status(:forbidden) |> json(%{error: "Webhook is inactive"})
  end

  defp handle_error(conn, :rate_limited) do
    conn
    |> put_status(:too_many_requests)
    |> json(%{error: "Rate limit exceeded. Please slow down."})
  end

  defp handle_error(conn, :invalid_content) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Content is required and must be at most 4000 characters"})
  end

  defp handle_error(conn, :invalid_override) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Invalid username or avatar_url override"})
  end

  defp handle_error(conn, %Ecto.Changeset{} = changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Validation failed", errors: format_errors(changeset)})
  end

  defp handle_error(conn, _reason) do
    conn |> put_status(:internal_server_error) |> json(%{error: "Something went wrong"})
  end

  # Serialization

  defp format_webhook(webhook) do
    base = %{
      id: webhook.id,
      conversation_id: webhook.conversation_id,
      name: webhook.name,
      avatar_url: webhook.avatar_url,
      active: webhook.active,
      creator_id: webhook.creator_id,
      created_at: webhook.inserted_at
    }

    # Plaintext token is only present right after create/rotate.
    case webhook.token do
      nil -> base
      token -> Map.put(base, :token, token)
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp with_valid_id(conn, value, fun) do
    case parse_id(value) do
      {:ok, id} -> fun.(id)
      :error -> conn |> put_status(:bad_request) |> json(%{error: "Invalid id"})
    end
  end

  defp parse_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(_value), do: :error
end
