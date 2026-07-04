defmodule Elektrine.Messaging.ChatWebhooks do
  @moduledoc """
  Context for incoming chat webhooks.

  Incoming webhooks let external services post text messages into channel
  and group conversations (never DMs). Management (create/list/update/
  rotate/deactivate/delete) requires the `manage_webhooks` permission: for
  channels this is resolved through `RoomACL` with the usual server
  owner/admin carve-out (mirroring `ChatMessagePins`); for groups it maps to
  the conversation member roles that carry `manage_webhooks` in the built-in
  role definitions (owner/admin).

  Execution requires no session: the webhook token IS the credential. The
  token is stored only as a SHA-256 hash and verified in constant time;
  unknown ids and bad tokens are indistinguishable (`{:error, :not_found}`)
  to avoid oracle behavior. Executions are rate limited per webhook.

  Webhook-authored messages go through the canonical
  `ChatMessages.create_webhook_text_message/4` path, so they broadcast over
  PubSub and federate exactly like normal messages.
  """

  import Ecto.Query, warn: false

  alias Elektrine.Messaging.{
    ChatConversation,
    ChatConversationMember,
    ChatMessages,
    ChatWebhook,
    RateLimiter,
    RoomACL,
    ServerMember
  }

  alias Elektrine.Repo

  @max_webhooks_per_conversation 15
  @max_content_length 4000
  @max_name_length 80
  @max_avatar_url_length 500

  # Built-in conversation roles that carry `manage_webhooks` (see RoomACL).
  @manage_webhook_roles ["owner", "admin"]

  @webhook_conversation_types ["channel", "group"]

  @doc """
  Maximum number of webhooks allowed per conversation.
  """
  def max_webhooks_per_conversation, do: @max_webhooks_per_conversation

  @doc """
  Creates a webhook on a channel or group conversation.

  Requires the `manage_webhooks` permission. On success the returned
  webhook carries the plaintext token in the virtual `:token` field --
  this is the only time the plaintext is available.
  """
  def create_webhook(conversation_id, user_id, attrs \\ %{}) do
    with {:ok, conversation} <- fetch_webhook_conversation(conversation_id),
         :ok <- authorize_manage_webhooks(conversation, user_id),
         :ok <- ensure_webhook_capacity(conversation.id) do
      {token, token_hash} = ChatWebhook.generate_token()

      %ChatWebhook{}
      |> ChatWebhook.changeset(%{
        conversation_id: conversation.id,
        creator_id: user_id,
        name: attrs_value(attrs, "name", :name),
        avatar_url: attrs_value(attrs, "avatar_url", :avatar_url),
        token_hash: token_hash,
        active: true
      })
      |> Repo.insert()
      |> case do
        {:ok, webhook} -> {:ok, %{webhook | token: token}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Lists the webhooks of a conversation. Requires `manage_webhooks`.
  """
  def list_webhooks(conversation_id, user_id) do
    with {:ok, conversation} <- fetch_webhook_conversation(conversation_id),
         :ok <- authorize_manage_webhooks(conversation, user_id) do
      webhooks =
        from(w in ChatWebhook,
          where: w.conversation_id == ^conversation.id,
          order_by: [asc: w.id]
        )
        |> Repo.all()

      {:ok, webhooks}
    end
  end

  @doc """
  Renames a webhook and/or updates its avatar. Requires `manage_webhooks`.
  """
  def update_webhook(webhook_id, user_id, attrs) do
    with {:ok, webhook, _conversation} <- fetch_authorized_webhook(webhook_id, user_id) do
      webhook
      |> ChatWebhook.update_changeset(%{
        name: attrs_value(attrs, "name", :name) || webhook.name,
        avatar_url: attrs_value(attrs, "avatar_url", :avatar_url)
      })
      |> Repo.update()
    end
  end

  @doc """
  Rotates a webhook's token. Requires `manage_webhooks`.

  The returned webhook carries the new plaintext token in the virtual
  `:token` field -- this is the only time the plaintext is available.
  """
  def rotate_webhook_token(webhook_id, user_id) do
    with {:ok, webhook, _conversation} <- fetch_authorized_webhook(webhook_id, user_id) do
      {token, token_hash} = ChatWebhook.generate_token()

      webhook
      |> ChatWebhook.rotate_token_changeset(token_hash)
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, %{updated | token: token}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Deactivates a webhook without deleting it. Requires `manage_webhooks`.
  """
  def deactivate_webhook(webhook_id, user_id) do
    with {:ok, webhook, _conversation} <- fetch_authorized_webhook(webhook_id, user_id) do
      webhook
      |> ChatWebhook.deactivate_changeset()
      |> Repo.update()
    end
  end

  @doc """
  Deletes a webhook. Requires `manage_webhooks`.
  """
  def delete_webhook(webhook_id, user_id) do
    with {:ok, webhook, _conversation} <- fetch_authorized_webhook(webhook_id, user_id) do
      Repo.delete(webhook)
    end
  end

  @doc """
  Executes a webhook: verifies the token and posts a text message into the
  webhook's conversation, authored as the webhook.

  No user authentication is involved -- the token is the credential.
  Returns `{:error, :not_found}` for unknown ids and bad tokens alike,
  `{:error, :webhook_inactive}` for deactivated webhooks (only reachable
  with a valid token), `{:error, :rate_limited}` past the per-webhook
  execution limit, and `{:error, :invalid_content}` /
  `{:error, :invalid_override}` for bad payloads.

  Supported params: `"content"` (required), `"username"` and
  `"avatar_url"` (optional display overrides for this message).
  """
  def execute_webhook(webhook_id, token, params) when is_binary(token) and is_map(params) do
    webhook = fetch_webhook(webhook_id)

    with :ok <- verify_webhook_token(webhook, token),
         :ok <- ensure_active(webhook),
         :ok <- check_rate_limit(webhook),
         {:ok, content} <- validate_content(attrs_value(params, "content", :content)),
         {:ok, name_override} <-
           validate_override(attrs_value(params, "username", :username), @max_name_length),
         {:ok, avatar_override} <-
           validate_override(
             attrs_value(params, "avatar_url", :avatar_url),
             @max_avatar_url_length
           ) do
      RateLimiter.record_webhook_execution(webhook.id)

      ChatMessages.create_webhook_text_message(
        webhook.conversation_id,
        webhook.id,
        content,
        webhook_sender_meta(webhook, name_override, avatar_override)
      )
    end
  end

  def execute_webhook(_webhook_id, _token, _params), do: {:error, :not_found}

  # Fetching and authorization

  defp fetch_webhook(webhook_id) when is_integer(webhook_id),
    do: Repo.get(ChatWebhook, webhook_id)

  defp fetch_webhook(webhook_id) when is_binary(webhook_id) do
    case Integer.parse(webhook_id) do
      {id, ""} -> fetch_webhook(id)
      _ -> nil
    end
  end

  defp fetch_webhook(_webhook_id), do: nil

  defp verify_webhook_token(%ChatWebhook{} = webhook, token) do
    if ChatWebhook.valid_token?(webhook, token) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp verify_webhook_token(nil, token) do
    # Burn a comparison so unknown ids cost the same as bad tokens.
    ChatWebhook.valid_token?(%ChatWebhook{token_hash: ChatWebhook.hash_token("")}, token)
    {:error, :not_found}
  end

  defp ensure_active(%ChatWebhook{active: true}), do: :ok
  defp ensure_active(_webhook), do: {:error, :webhook_inactive}

  defp check_rate_limit(%ChatWebhook{id: webhook_id}) do
    if RateLimiter.can_execute_webhook?(webhook_id) do
      :ok
    else
      {:error, :rate_limited}
    end
  end

  defp validate_content(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" -> {:error, :invalid_content}
      String.length(trimmed) > @max_content_length -> {:error, :invalid_content}
      true -> {:ok, trimmed}
    end
  end

  defp validate_content(_content), do: {:error, :invalid_content}

  defp validate_override(nil, _max_length), do: {:ok, nil}

  defp validate_override(value, max_length) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) > max_length -> {:error, :invalid_override}
      true -> {:ok, trimmed}
    end
  end

  defp validate_override(_value, _max_length), do: {:error, :invalid_override}

  defp webhook_sender_meta(%ChatWebhook{} = webhook, name_override, avatar_override) do
    %{
      "webhook_id" => webhook.id,
      "name" => name_override || webhook.name,
      "avatar_url" => avatar_override || webhook.avatar_url
    }
  end

  defp fetch_webhook_conversation(conversation_id) do
    case Repo.get(ChatConversation, conversation_id) do
      %ChatConversation{type: type, is_federated_mirror: false} = conversation
      when type in @webhook_conversation_types ->
        {:ok, conversation}

      %ChatConversation{} ->
        {:error, :unsupported_conversation}

      nil ->
        {:error, :not_found}
    end
  end

  defp fetch_authorized_webhook(webhook_id, user_id) do
    with %ChatWebhook{} = webhook <- fetch_webhook(webhook_id),
         %ChatConversation{} = conversation <- Repo.get(ChatConversation, webhook.conversation_id),
         :ok <- authorize_manage_webhooks(conversation, user_id) do
      {:ok, webhook, conversation}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_manage_webhooks(%ChatConversation{} = conversation, user_id)
       when is_integer(user_id) do
    case conversation do
      %ChatConversation{type: "channel", server_id: server_id} when is_integer(server_id) ->
        # Server owners/admins manage webhooks (mirrors the carve-out in
        # ChatMessagePins); other members go through the room ACL.
        if server_staff?(server_id, user_id) do
          :ok
        else
          RoomACL.authorize_local_user_action(conversation.id, user_id, :manage_webhooks)
        end

      %ChatConversation{type: "channel"} ->
        RoomACL.authorize_local_user_action(conversation.id, user_id, :manage_webhooks)

      %ChatConversation{type: "group"} ->
        member =
          from(cm in ChatConversationMember,
            where:
              cm.conversation_id == ^conversation.id and cm.user_id == ^user_id and
                is_nil(cm.left_at)
          )
          |> Repo.one()

        case member do
          %ChatConversationMember{role: role} when role in @manage_webhook_roles -> :ok
          _ -> {:error, :unauthorized}
        end

      %ChatConversation{} ->
        {:error, :unsupported_conversation}
    end
  end

  defp authorize_manage_webhooks(_conversation, _user_id), do: {:error, :unauthorized}

  defp server_staff?(server_id, user_id) do
    from(sm in ServerMember,
      where:
        sm.server_id == ^server_id and sm.user_id == ^user_id and is_nil(sm.left_at) and
          sm.role in ^@manage_webhook_roles
    )
    |> Repo.exists?()
  end

  defp ensure_webhook_capacity(conversation_id) do
    count =
      from(w in ChatWebhook, where: w.conversation_id == ^conversation_id, select: count())
      |> Repo.one()

    if count < @max_webhooks_per_conversation do
      :ok
    else
      {:error, :webhook_limit_reached}
    end
  end

  defp attrs_value(attrs, string_key, atom_key) do
    Map.get(attrs, string_key) || Map.get(attrs, atom_key)
  end
end
