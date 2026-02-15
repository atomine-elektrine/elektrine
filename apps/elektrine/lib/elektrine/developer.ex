defmodule Elektrine.Developer do
  @moduledoc """
  The Developer context.

  Handles Personal Access Tokens (PATs), data exports, and webhooks
  for developer/hacker-friendly API access.
  """

  import Ecto.Query, warn: false
  alias Elektrine.Repo
  alias Elektrine.Developer.ApiToken
  alias Elektrine.Developer.Webhook

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

          true ->
            # Update last used (async to not block auth)
            Task.start(fn ->
              token
              |> ApiToken.touch_changeset(ip_address)
              |> Repo.update()
            end)

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

        deliver_webhook(webhook, "webhook.test", test_payload)
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
      {webhook.id, deliver_webhook(webhook, event, payload)}
    end)
  end

  defp deliver_webhook(%Webhook{} = webhook, event, payload) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
    body = build_webhook_body(event, payload, timestamp)
    signature = sign_webhook_payload(webhook.secret, body)

    headers = [
      {"content-type", "application/json"},
      {"user-agent", "Elektrine-Webhooks/1.0"},
      {"x-elektrine-event", event},
      {"x-elektrine-timestamp", DateTime.to_iso8601(timestamp)},
      {"x-elektrine-signature", "sha256=#{signature}"}
    ]

    request = Finch.build(:post, webhook.url, headers, body)

    case Finch.request(request, Elektrine.Finch, receive_timeout: 5_000, pool_timeout: 5_000) do
      {:ok, %Finch.Response{status: status}} when status >= 200 and status < 300 ->
        update_webhook_delivery_status(webhook, timestamp, status, nil)
        {:ok, status}

      {:ok, %Finch.Response{status: status}} ->
        update_webhook_delivery_status(webhook, timestamp, status, "HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        update_webhook_delivery_status(webhook, timestamp, nil, request_error_message(reason))
        {:error, {:request_failed, reason}}
    end
  end

  defp build_webhook_body(event, payload, timestamp) do
    Jason.encode!(%{
      id: Ecto.UUID.generate(),
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

  defp request_error_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp request_error_message(reason), do: inspect(reason)

  # =============================================================================
  # Data Exports
  # =============================================================================

  alias Elektrine.Developer.DataExport

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
    export
    |> DataExport.complete_changeset(file_path, file_size, item_count)
    |> Repo.update()
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
end
