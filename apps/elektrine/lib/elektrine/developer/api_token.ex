defmodule Elektrine.Developer.ApiToken do
  @moduledoc """
  Schema for Personal Access Tokens (PATs).

  PATs allow users to authenticate with the API using long-lived tokens
  with specific scopes, similar to GitHub/GitLab personal access tokens.

  ## Token Format

  Tokens use the format: `ekt_<32 random bytes base64>`
  Example: `ekt_a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6`

  The `ekt_` prefix makes tokens easy to identify in logs and code.

  ## Scopes

  Tokens can have fine-grained scopes:
  - `read:email` - Read emails, folders, labels
  - `write:email` - Send, delete, move emails
  - `read:social` - Read posts, profile, followers
  - `write:social` - Create posts, follow, like
  - `read:chat` - Read conversations, messages
  - `write:chat` - Send messages, create conversations
  - `read:contacts` - Read contacts/addressbook
  - `write:contacts` - Create/update/delete contacts
  - `read:calendar` - Read calendar events
  - `write:calendar` - Create/update/delete events
  - `read:account` - Read account info, settings
  - `write:account` - Update settings (not password)
  - `read:vault` - Read encrypted password vault entries
  - `write:vault` - Create/update/delete encrypted password vault entries
  - `export` - Trigger and download data exports
  - `webhook` - Manage webhook subscriptions
  """
  use Ecto.Schema
  import Ecto.Changeset

  @valid_scopes ~w(
    read:email write:email
    read:social write:social
    read:chat write:chat
    read:contacts write:contacts
    read:calendar write:calendar
    read:account write:account
    read:vault write:vault
    export webhook
  )
  @token_presets [
    %{
      id: "search_read_only",
      name: "Read-only search",
      description: "Search across account data without write access.",
      scopes: [
        "read:account",
        "read:email",
        "read:chat",
        "read:social",
        "read:contacts",
        "read:calendar"
      ]
    },
    %{
      id: "calendar_sync",
      name: "Calendar sync",
      description: "Read and write calendar events for sync tools or bots.",
      scopes: ["read:calendar", "write:calendar"]
    },
    %{
      id: "backup_export",
      name: "Backup and export",
      description: "Trigger and download account exports.",
      scopes: ["export"]
    },
    %{
      id: "webhook_admin",
      name: "Webhook admin",
      description: "Create, test, rotate, and inspect webhook subscriptions.",
      scopes: ["webhook"]
    },
    %{
      id: "vault_access",
      name: "Vault access",
      description: "Read and write encrypted password vault entries.",
      scopes: ["read:vault", "write:vault"]
    }
  ]

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :string
    field :token_prefix, :string
    field :scopes, {:array, :string}, default: []
    field :last_used_at, :utc_datetime
    field :last_used_ip, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    # Virtual field for returning the token once on creation
    field :token, :string, virtual: true

    belongs_to :user, Elektrine.Accounts.User

    timestamps()
  end

  @doc """
  Returns list of all valid scopes.
  """
  def valid_scopes, do: @valid_scopes

  @doc """
  Returns recommended token presets for common integrations.
  """
  def token_presets, do: @token_presets

  @doc """
  Returns the preferred default token expiration in days.
  """
  def default_expiration_days, do: 90

  @doc """
  Returns the scopes for a preset id.
  """
  def preset_scopes(preset_id) when is_binary(preset_id) do
    case Enum.find(@token_presets, &(&1.id == preset_id)) do
      %{scopes: scopes} -> scopes
      _ -> []
    end
  end

  def preset_scopes(_preset_id), do: []

  @doc """
  Finds a preset that matches a scope list exactly.
  """
  def preset_for_scopes(scopes) when is_list(scopes) do
    normalized = normalize_scope_list(scopes)

    Enum.find_value(@token_presets, "custom", fn preset ->
      if normalize_scope_list(preset.scopes) == normalized, do: preset.id
    end)
  end

  def preset_for_scopes(_), do: "custom"

  @doc """
  Returns scopes grouped by category for UI display.
  """
  def scopes_by_category do
    %{
      "Email" => [
        {"read:email", "Read emails, folders, and labels"},
        {"write:email", "Send, delete, and move emails"}
      ],
      "Social" => [
        {"read:social", "Read posts, profile, and followers"},
        {"write:social", "Create posts, follow users, and like content"}
      ],
      "Chat" => [
        {"read:chat", "Read conversations and messages"},
        {"write:chat", "Send messages and create conversations"}
      ],
      "Contacts" => [
        {"read:contacts", "Read contacts and addressbook"},
        {"write:contacts", "Create, update, and delete contacts"}
      ],
      "Calendar" => [
        {"read:calendar", "Read calendar events"},
        {"write:calendar", "Create, update, and delete events"}
      ],
      "Account" => [
        {"read:account", "Read account info and settings"},
        {"write:account", "Update account settings"}
      ],
      "Vault" => [
        {"read:vault", "Read encrypted password vault entries"},
        {"write:vault", "Create, update, and delete vault entries"}
      ],
      "Developer" => [
        {"export", "Trigger and download data exports"},
        {"webhook", "Manage webhook subscriptions"}
      ]
    }
  end

  @doc """
  Changeset for creating a new API token.
  """
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:name, :token_hash, :token_prefix, :scopes, :expires_at, :user_id])
    |> validate_required([:name, :token_hash, :token_prefix, :user_id])
    |> validate_length(:name, min: 1, max: 100)
    |> update_change(:scopes, &normalize_scope_list/1)
    |> validate_scope_selection()
    |> validate_scopes()
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Changeset for revoking a token.
  """
  def revoke_changeset(api_token) do
    api_token
    |> change(%{revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)})
  end

  @doc """
  Changeset for updating last used info.
  """
  def touch_changeset(api_token, ip_address \\ nil) do
    changes = %{last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)}
    changes = if ip_address, do: Map.put(changes, :last_used_ip, ip_address), else: changes

    api_token
    |> change(changes)
  end

  @doc """
  Generate a new API token.
  Returns {raw_token, token_hash, token_prefix}.
  """
  def generate_token do
    raw_token = "ekt_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    token_hash = hash_token(raw_token)
    token_prefix = String.slice(raw_token, 0, 12)
    {raw_token, token_hash, token_prefix}
  end

  @doc """
  Hash a token for storage using SHA256.
  """
  def hash_token(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  @doc """
  Check if the token has expired.
  """
  def expired?(%__MODULE__{expires_at: nil}), do: false

  def expired?(%__MODULE__{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end

  @doc """
  Check if the token has been revoked.
  """
  def revoked?(%__MODULE__{revoked_at: nil}), do: false
  def revoked?(%__MODULE__{revoked_at: _}), do: true

  @doc """
  Check if the token is valid (not expired and not revoked).
  """
  def valid?(%__MODULE__{} = token) do
    not expired?(token) and not revoked?(token)
  end

  @doc """
  Check if the token has a specific scope.
  """
  def has_scope?(%__MODULE__{scopes: scopes}, scope) do
    scope in scopes
  end

  @doc """
  Check if the token has any of the given scopes.
  """
  def has_any_scope?(%__MODULE__{scopes: scopes}, required_scopes)
      when is_list(required_scopes) do
    Enum.any?(required_scopes, &(&1 in scopes))
  end

  @doc """
  Check if the token can read a resource type.
  """
  def can_read?(%__MODULE__{} = token, resource) do
    has_scope?(token, "read:#{resource}")
  end

  @doc """
  Check if the token can write a resource type.
  """
  def can_write?(%__MODULE__{} = token, resource) do
    has_scope?(token, "write:#{resource}")
  end

  # Validate that all scopes are valid
  defp validate_scopes(changeset) do
    case get_change(changeset, :scopes) do
      nil ->
        changeset

      scopes ->
        invalid = Enum.filter(scopes, &(&1 not in @valid_scopes))

        if Enum.empty?(invalid) do
          changeset
        else
          add_error(changeset, :scopes, "contains invalid scopes: #{Enum.join(invalid, ", ")}")
        end
    end
  end

  defp validate_scope_selection(changeset) do
    scopes = get_field(changeset, :scopes, [])

    if Enum.empty?(scopes) do
      add_error(changeset, :scopes, "must include at least one scope")
    else
      changeset
    end
  end

  defp normalize_scope_list(scopes) when is_list(scopes) do
    scopes
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_scope_list(_), do: []
end
