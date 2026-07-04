defmodule Elektrine.Messaging.ChatWebhook do
  @moduledoc """
  Schema for incoming chat webhooks.

  A webhook lets external services post messages into a channel or group
  conversation. The secret token is stored only as a SHA-256 hash (same
  storage pattern as personal access tokens); the plaintext token is
  returned exactly once on creation or rotation via the virtual `:token`
  field.

  Webhook-authored messages have no local sender. They carry the webhook id
  on the message row plus display metadata (name/avatar) in the message's
  `media_metadata`, so clients can render the webhook as the author.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @token_prefix "ewh_"

  schema "chat_webhooks" do
    field :name, :string
    field :avatar_url, :string
    field :token_hash, :string
    field :active, :boolean, default: true

    # Virtual field for returning the plaintext token once on create/rotate.
    field :token, :string, virtual: true

    belongs_to :conversation, Elektrine.Messaging.ChatConversation
    belongs_to :creator, Elektrine.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:conversation_id, :creator_id, :name, :avatar_url, :token_hash, :active])
    |> validate_required([:conversation_id, :name, :token_hash])
    |> validate_name_and_avatar()
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:creator_id)
  end

  @doc """
  Changeset for renaming a webhook or updating its avatar.
  """
  def update_changeset(webhook, attrs) do
    webhook
    |> cast(attrs, [:name, :avatar_url])
    |> validate_required([:name])
    |> validate_name_and_avatar()
  end

  @doc """
  Changeset for storing a rotated token hash.
  """
  def rotate_token_changeset(webhook, token_hash) do
    webhook
    |> change(%{token_hash: token_hash})
    |> unique_constraint(:token_hash)
  end

  @doc """
  Changeset for deactivating a webhook.
  """
  def deactivate_changeset(webhook) do
    change(webhook, %{active: false})
  end

  @doc """
  Generates a new webhook token.

  Returns `{plaintext_token, token_hash}`. Only the hash is persisted.
  """
  def generate_token do
    token = @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {token, hash_token(token)}
  end

  @doc """
  Hashes a webhook token for storage using SHA-256 (same pattern as
  `Elektrine.Developer.ApiToken`).
  """
  def hash_token(token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  @doc """
  Verifies a plaintext token against the stored hash in constant time.
  """
  def valid_token?(%__MODULE__{token_hash: token_hash}, token)
      when is_binary(token_hash) and is_binary(token) do
    Plug.Crypto.secure_compare(hash_token(token), token_hash)
  end

  def valid_token?(_webhook, _token), do: false

  defp validate_name_and_avatar(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 80)
    |> validate_length(:avatar_url, max: 500)
  end
end
