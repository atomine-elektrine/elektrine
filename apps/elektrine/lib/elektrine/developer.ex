defmodule Elektrine.Developer do
  @moduledoc """
  The Developer context.

  Handles Personal Access Tokens (PATs), data exports, and webhooks
  for developer/hacker-friendly API access.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Developer.{
    ApiToken,
    DataExport,
    Webhook,
    WebhookDelivery,
    WebhookDeliveryWorker
  }

  alias Elektrine.Accounts.Authentication
  alias Elektrine.HTTP.SafeFetch
  alias Elektrine.Repo

  # =============================================================================
  # API Tokens
  # =============================================================================

  @doc """
  Lists all active (non-revoked) API tokens for a user.
  """
  def list_api_tokens(user_id) do
    ApiToken
    |> where([t], t.user_id == ^user_id and is_nil(t.revoked_at))
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single API token by ID for a user.
  Returns nil if not found or revoked.
  """
  def get_api_token(user_id, token_id) do
    ApiToken
    |> where([t], t.id == ^token_id and t.user_id == ^user_id and is_nil(t.revoked_at))
    |> Repo.one()
  end

  @doc """
  Gets an API token by its raw token string.
  Used for authentication.
  """
  def get_api_token_by_token(raw_token) do
    token_hash = ApiToken.hash_token(raw_token)

    ApiToken
    |> where([t], t.token_hash == ^token_hash and is_nil(t.revoked_at))
    |> preload(:user)
    |> Repo.one()
  end

  @doc """
  Creates a new API token for a user.

  Returns `{:ok, token}` with the raw token in the virtual `:token` field.
  The raw token is only available at creation time.

  ## Options

  - `:name` - Required. Name for the token.
  - `:scopes` - Required. List of scope strings.
  - `:expires_at` - Optional. Expiration datetime.
  """
  def create_api_token(user_id, attrs) do
    if count_api_tokens(user_id) >= max_tokens_per_user() do
      changeset =
        %ApiToken{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(
          :name,
          "token limit reached (maximum #{max_tokens_per_user()} active tokens)"
        )

      {:error, changeset}
    else
      {raw_token, token_hash, token_prefix} = ApiToken.generate_token()

      attrs =
        attrs
        |> Map.put(:user_id, user_id)
        |> Map.put(:token_hash, token_hash)
        |> Map.put(:token_prefix, token_prefix)

      case %ApiToken{}
           |> ApiToken.changeset(attrs)
           |> Repo.insert() do
        {:ok, token} ->
          # Return with raw token in virtual field (only time it's available)
          {:ok, %{token | token: raw_token}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Revokes an API token.
  """
  def revoke_api_token(user_id, token_id) do
    case get_api_token(user_id, token_id) do
      nil ->
        {:error, :not_found}

      token ->
        token
        |> ApiToken.revoke_changeset()
        |> Repo.update()
    end
  end

  @doc """
  Revokes all API tokens for a user.
  """
  def revoke_all_api_tokens(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      ApiToken
      |> where([t], t.user_id == ^user_id and is_nil(t.revoked_at))
      |> Repo.update_all(set: [revoked_at: now])

    {:ok, count}
  end

  @doc """
  Verifies an API token and returns the token struct with user if valid.
  Updates last_used_at timestamp.

  Returns `{:ok, token}` or `{:error, reason}`.
  """
  def verify_api_token(raw_token, ip_address \\ nil) do
    case get_api_token_by_token(raw_token) do
      nil ->
        {:error, :invalid_token}

      token ->
        cond do
          ApiToken.expired?(token) ->
            {:error, :token_expired}

          ApiToken.revoked?(token) ->
            {:error, :token_revoked}

          Authentication.ensure_user_active(token.user) != :ok ->
            {:error, :account_inactive}

          true ->
            touch_api_token(token, ip_address)

            {:ok, token}
        end
    end
  end

  @doc """
  Checks if a token has the required scope(s).
  """
  def check_scope(%ApiToken{} = token, required_scope) when is_binary(required_scope) do
    if ApiToken.has_scope?(token, required_scope) do
      :ok
    else
      {:error, :insufficient_scope}
    end
  end

  def check_scope(%ApiToken{} = token, required_scopes) when is_list(required_scopes) do
    if ApiToken.has_any_scope?(token, required_scopes) do
      :ok
    else
      {:error, :insufficient_scope}
    end
  end

  @doc """
  Counts active tokens for a user.
  """
  def count_api_tokens(user_id) do
    ApiToken
    |> where([t], t.user_id == ^user_id and is_nil(t.revoked_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  Maximum number of tokens allowed per user.
  """
  def max_tokens_per_user, do: 20

  # =============================================================================
  # Webhooks
  # =============================================================================

  @doc """
  Lists webhook subscriptions for a user.
  """
  def list_webhooks(user_id) do
    Webhook
    |> where([w], w.user_id == ^user_id)
    |> order_by([w], desc: w.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a webhook subscription by id for a user.
  """
  def get_webhook(user_id, webhook_id) do
    Webhook
    |> where([w], w.id == ^webhook_id and w.user_id == ^user_id)
    |> Repo.one()
  end

  @doc """
  Creates a new webhook subscription.
  """
  def create_webhook(user_id, attrs) do
    attrs = Map.put(attrs, :user_id, user_id)

    %Webhook{}
    |> Webhook.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes a webhook subscription.
  """
  def delete_webhook(user_id, webhook_id) do
    case get_webhook(user_id, webhook_id) do
      nil -> {:error, :not_found}
      webhook -> Repo.delete(webhook)
    end
  end

  @doc """
  Rotates the signing secret for a webhook.
  """
  def rotate_webhook_secret(user_id, webhook_id) do
    case get_webhook(user_id, webhook_id) do
      nil ->
        {:error, :not_found}

      webhook ->
        new_secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        webhook
        |> Ecto.Changeset.change(%{secret: new_secret})
        |> Repo.update()
    end
  end

  @doc """
  Lists recent webhook deliveries for a user.
  """
  def list_webhook_deliveries(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    webhook_id = Keyword.get(opts, :webhook_id)

    WebhookDelivery
    |> where([d], d.user_id == ^user_id)
    |> maybe_filter_webhook(webhook_id)
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets a webhook delivery by id.
  """
  def get_webhook_delivery(delivery_id) do
    WebhookDelivery
    |> where([d], d.id == ^delivery_id)
    |> preload(:webhook)
    |> Repo.one()
  end

  @doc """
  Gets a webhook delivery by id for a specific user.
  """
  def get_webhook_delivery(user_id, delivery_id) do
    WebhookDelivery
    |> where([d], d.id == ^delivery_id and d.user_id == ^user_id)
    |> preload(:webhook)
    |> Repo.one()
  end

  @doc """
  Sends a test webhook delivery.
  """
  def test_webhook(user_id, webhook_id) do
    case get_webhook(user_id, webhook_id) do
      nil ->
        {:error, :not_found}

      webhook ->
        test_payload = %{
          message: "This is a test delivery from Elektrine.",
          webhook_id: webhook.id,
          user_id: user_id
        }

        with {:ok, delivery} <- create_webhook_delivery(webhook, "webhook.test", test_payload) do
          run_webhook_delivery(%{delivery | webhook: webhook}, 1)
        end
    end
  end

  @doc """
  Replays a historical webhook delivery by creating a fresh delivery attempt.
  """
  def replay_webhook_delivery(user_id, delivery_id) do
    case get_webhook_delivery(user_id, delivery_id) do
      nil ->
        {:error, :not_found}

      %WebhookDelivery{} = delivery ->
        case get_webhook(user_id, delivery.webhook_id) do
          nil ->
            {:error, :not_found}

          webhook ->
            enqueue_webhook_delivery(webhook, delivery.event, delivery.payload)
        end
    end
  end

  @doc """
  Delivers an event to all enabled webhooks that are subscribed to it.
  """
  def deliver_event(user_id, event, payload) when is_binary(event) and is_map(payload) do
    webhooks =
      Webhook
      |> where([w], w.user_id == ^user_id and w.enabled == true)
      |> where([w], ^event in w.events)
      |> Repo.all()

    Enum.map(webhooks, fn webhook ->
      {webhook.id, enqueue_webhook_delivery(webhook, event, payload)}
    end)
  end

  @doc """
  Processes one queued webhook delivery attempt.
  """
  def process_webhook_delivery(delivery_id, attempt \\ 1) do
    case get_webhook_delivery(delivery_id) do
      nil ->
        {:error, :not_found}

      delivery ->
        run_webhook_delivery(delivery, attempt)
    end
  end

  defp enqueue_webhook_delivery(%Webhook{} = webhook, event, payload) do
    with {:ok, delivery} <- create_webhook_delivery(webhook, event, payload) do
      case %{delivery_id: delivery.id}
           |> WebhookDeliveryWorker.new()
           |> Elektrine.JobQueue.insert() do
        {:ok, _job} ->
          {:ok, :queued}

        {:error, reason} ->
          _ =
            update_webhook_delivery_result(delivery, %{
              status: "failed",
              attempt_count: 0,
              error: "Failed to enqueue delivery: #{inspect(reason)}"
            })

          {:error, {:enqueue_failed, reason}}
      end
    end
  end

  defp create_webhook_delivery(%Webhook{} = webhook, event, payload) do
    %WebhookDelivery{}
    |> WebhookDelivery.changeset(%{
      webhook_id: webhook.id,
      user_id: webhook.user_id,
      event: event,
      event_id: Ecto.UUID.generate(),
      payload: payload,
      status: "pending"
    })
    |> Repo.insert()
  end

  defp run_webhook_delivery(%WebhookDelivery{status: "delivered"} = delivery, _attempt) do
    {:ok, delivery.response_status || 200}
  end

  defp run_webhook_delivery(%WebhookDelivery{} = delivery, attempt) do
    webhook = delivery.webhook

    cond do
      is_nil(webhook) ->
        timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

        _ =
          update_webhook_delivery_result(delivery, %{
            status: "failed",
            attempt_count: attempt,
            error: "Webhook not found",
            last_attempted_at: timestamp
          })

        {:error, :not_found}

      not webhook.enabled ->
        timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

        _ =
          update_webhook_delivery_result(delivery, %{
            status: "failed",
            attempt_count: attempt,
            error: "Webhook is disabled",
            last_attempted_at: timestamp
          })

        {:error, :webhook_disabled}

      true ->
        deliver_webhook(webhook, delivery, attempt)
    end
  end

  defp deliver_webhook(%Webhook{} = webhook, %WebhookDelivery{} = delivery, attempt) do
    case Webhook.validate_url(webhook.url) do
      :ok ->
        timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
        started_ms = System.monotonic_time(:millisecond)
        body = build_webhook_body(delivery.event, delivery.payload, timestamp, delivery.event_id)
        signature = sign_webhook_payload(webhook.secret, body)

        headers = [
          {"content-type", "application/json"},
          {"user-agent", "Elektrine-Webhooks/1.0"},
          {"x-elektrine-event", delivery.event},
          {"x-elektrine-delivery-id", delivery.event_id},
          {"x-elektrine-timestamp", DateTime.to_iso8601(timestamp)},
          {"x-elektrine-signature", "sha256=#{signature}"}
        ]

        request = Finch.build(:post, webhook.url, headers, body)
        duration_ms = fn -> System.monotonic_time(:millisecond) - started_ms end

        case SafeFetch.request(request, Elektrine.Finch,
               receive_timeout: 5_000,
               pool_timeout: 5_000,
               max_body_bytes: 256_000,
               allow_localhost: Mix.env() in [:dev, :test]
             ) do
          {:ok, %Finch.Response{status: status}} when status >= 200 and status < 300 ->
            _ =
              update_webhook_delivery_result(delivery, %{
                status: "delivered",
                attempt_count: attempt,
                response_status: status,
                error: nil,
                duration_ms: duration_ms.(),
                last_attempted_at: timestamp,
                delivered_at: timestamp
              })

            update_webhook_delivery_status(webhook, timestamp, status, nil)
            {:ok, status}

          {:ok, %Finch.Response{status: status}} ->
            _ =
              update_webhook_delivery_result(delivery, %{
                status: "failed",
                attempt_count: attempt,
                response_status: status,
                error: "HTTP #{status}",
                duration_ms: duration_ms.(),
                last_attempted_at: timestamp
              })

            update_webhook_delivery_status(webhook, timestamp, status, "HTTP #{status}")
            {:error, {:http_error, status}}

          {:error, reason} ->
            error_message = request_error_message(reason)

            _ =
              update_webhook_delivery_result(delivery, %{
                status: "failed",
                attempt_count: attempt,
                response_status: nil,
                error: error_message,
                duration_ms: duration_ms.(),
                last_attempted_at: timestamp
              })

            update_webhook_delivery_status(webhook, timestamp, nil, request_error_message(reason))
            {:error, {:request_failed, reason}}
        end

      {:error, reason} ->
        timestamp = DateTime.utc_now() |> DateTime.truncate(:second)

        _ =
          update_webhook_delivery_result(delivery, %{
            status: "failed",
            attempt_count: attempt,
            response_status: nil,
            error: "Unsafe webhook URL: #{reason}",
            duration_ms: 0,
            last_attempted_at: timestamp
          })

        update_webhook_delivery_status(webhook, timestamp, nil, "Unsafe webhook URL: #{reason}")
        {:error, {:unsafe_url, reason}}
    end
  end

  defp build_webhook_body(event, payload, timestamp, event_id) do
    Jason.encode!(%{
      id: event_id,
      event: event,
      sent_at: DateTime.to_iso8601(timestamp),
      data: payload
    })
  end

  defp sign_webhook_payload(secret, payload) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  defp update_webhook_delivery_status(webhook, timestamp, status, error) do
    webhook
    |> Webhook.delivery_result_changeset(%{
      last_triggered_at: timestamp,
      last_response_status: status,
      last_error: error
    })
    |> Repo.update()
  end

  defp update_webhook_delivery_result(delivery, attrs) do
    delivery
    |> WebhookDelivery.result_changeset(attrs)
    |> Repo.update()
  end

  defp maybe_filter_webhook(query, nil), do: query

  defp maybe_filter_webhook(query, webhook_id) do
    where(query, [d], d.webhook_id == ^webhook_id)
  end

  defp request_error_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp request_error_message(reason), do: inspect(reason)

  defp touch_api_token(token, ip_address) do
    update_fun = fn ->
      token
      |> ApiToken.touch_changeset(ip_address)
      |> Repo.update()
    end

    if test_env?() do
      _ = update_fun.()
      :ok
    else
      Task.start(fn ->
        try do
          _ = update_fun.()
        rescue
          _ -> :ok
        end
      end)

      :ok
    end
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  # =============================================================================
  # Data Exports
  # =============================================================================

  @doc """
  Lists recent exports for a user.
  """
  def list_exports(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    DataExport
    |> where([e], e.user_id == ^user_id)
    |> order_by([e], desc: e.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets an export by ID for a user.
  """
  def get_export(user_id, export_id) do
    DataExport
    |> where([e], e.id == ^export_id and e.user_id == ^user_id)
    |> Repo.one()
  end

  @doc """
  Gets an export by download token.
  """
  def get_export_by_token(download_token) do
    DataExport
    |> where([e], e.download_token == ^download_token)
    |> preload(:user)
    |> Repo.one()
  end

  @doc """
  Creates a new export request.
  """
  def create_export(user_id, attrs) do
    attrs = Map.put(attrs, :user_id, user_id)

    %DataExport{}
    |> DataExport.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Starts processing an export.
  """
  def start_export(%DataExport{} = export) do
    export
    |> DataExport.start_changeset()
    |> Repo.update()
  end

  @doc """
  Marks an export as completed.
  """
  def complete_export(%DataExport{} = export, file_path, file_size, item_count) do
    result =
      export
      |> DataExport.complete_changeset(file_path, file_size, item_count)
      |> Repo.update()

    case result do
      {:ok, completed_export} = ok ->
        maybe_emit_export_completed_webhook(completed_export)
        ok

      error ->
        error
    end
  end

  @doc """
  Marks an export as failed.
  """
  def fail_export(%DataExport{} = export, error) do
    export
    |> DataExport.fail_changeset(error)
    |> Repo.update()
  end

  @doc """
  Records a download of an export.
  """
  def record_download(%DataExport{} = export) do
    export
    |> DataExport.download_changeset()
    |> Repo.update()
  end

  @doc """
  Deletes an export and its file.
  """
  def delete_export(%DataExport{} = export) do
    # Delete file if it exists
    if export.file_path && File.exists?(export.file_path) do
      File.rm(export.file_path)
    end

    Repo.delete(export)
  end

  @doc """
  Cleans up expired exports.
  """
  def cleanup_expired_exports do
    now = DateTime.utc_now()

    expired =
      DataExport
      |> where([e], e.expires_at < ^now and e.status == "completed")
      |> Repo.all()

    Enum.each(expired, fn export ->
      # Delete file
      if export.file_path && File.exists?(export.file_path) do
        File.rm(export.file_path)
      end

      # Update status to expired
      export
      |> Ecto.Changeset.change(%{status: "expired"})
      |> Repo.update()
    end)

    length(expired)
  end

  @doc """
  Gets pending exports for a user (for UI display).
  """
  def get_pending_exports(user_id) do
    DataExport
    |> where([e], e.user_id == ^user_id and e.status in ["pending", "processing", "completed"])
    |> where([e], e.expires_at > ^DateTime.utc_now() or is_nil(e.expires_at))
    |> order_by([e], desc: e.inserted_at)
    |> limit(5)
    |> Repo.all()
  end

  defp maybe_emit_export_completed_webhook(%DataExport{} = export) do
    payload = %{
      export_id: export.id,
      type: export.export_type,
      format: export.format,
      file_size: export.file_size,
      item_count: export.item_count,
      completed_at: export.completed_at
    }

    _ = deliver_event(export.user_id, "export.completed", payload)
    :ok
  rescue
    _ -> :ok
  end
end
