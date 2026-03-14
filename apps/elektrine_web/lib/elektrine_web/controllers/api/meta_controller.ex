defmodule ElektrineWeb.API.MetaController do
  @moduledoc """
  External API metadata and token introspection endpoints.
  """

  use ElektrineWeb, :controller

  alias Elektrine.Developer.ApiToken
  alias Elektrine.Platform.Modules
  alias Elektrine.Developer.Webhook
  alias ElektrineWeb.API.Response

  @doc """
  GET /api/ext/v1/me
  """
  def me(conn, _params) do
    user = conn.assigns.current_user
    token = conn.assigns.api_token

    Response.ok(conn, %{
      user: %{
        id: user.id,
        username: user.username,
        handle: user.handle,
        display_name: user.display_name
      },
      token: %{
        id: token.id,
        name: token.name,
        token_prefix: token.token_prefix,
        scopes: token.scopes || [],
        inserted_at: token.inserted_at,
        expires_at: token.expires_at,
        last_used_at: token.last_used_at
      }
    })
  end

  @doc """
  GET /api/ext/v1/capabilities
  """
  def capabilities(conn, _params) do
    token = conn.assigns.api_token
    scopes = Map.get(token, :scopes, [])

    Response.ok(conn, %{
      api_version: "ext-v1",
      token: %{
        id: token.id,
        name: token.name,
        token_prefix: token.token_prefix,
        scopes: scopes,
        expires_at: token.expires_at
      },
      capabilities: %{
        modules: %{
          enabled: Modules.enabled(),
          available: Enum.map(Modules.specs(), &Map.take(&1, [:id, :label, :description]))
        },
        available_scopes: ApiToken.valid_scopes(),
        token_presets: Enum.map(ApiToken.token_presets(), &format_token_preset/1),
        webhook_events: Webhook.valid_events(),
        response_conventions: %{
          request_id_field: "meta.request_id",
          rate_limit_headers: ["x-ratelimit-limit", "x-ratelimit-remaining", "x-ratelimit-reset"],
          auth_headers: ["authorization", "x-api-key"]
        },
        endpoints: allowed_endpoints(scopes)
      }
    })
  end

  defp allowed_endpoints(scopes) do
    normalized_scopes = MapSet.new(scopes || [])

    endpoint_catalog()
    |> Enum.filter(&endpoint_module_enabled?/1)
    |> Enum.filter(&endpoint_allowed?(&1, normalized_scopes))
    |> Enum.map(fn endpoint ->
      Map.take(endpoint, [:method, :path, :summary, :required_scopes])
    end)
  end

  defp endpoint_allowed?(%{required_scopes: []}, _scopes), do: true

  defp endpoint_allowed?(%{match: :all, required_scopes: required_scopes}, scopes) do
    Enum.all?(required_scopes, &MapSet.member?(scopes, &1))
  end

  defp endpoint_allowed?(%{required_scopes: required_scopes}, scopes) do
    Enum.any?(required_scopes, &MapSet.member?(scopes, &1))
  end

  defp format_token_preset(preset) do
    %{
      id: preset.id,
      name: preset.name,
      description: preset.description,
      scopes: preset.scopes
    }
  end

  defp endpoint_module_enabled?(%{platform_module: nil}), do: true
  defp endpoint_module_enabled?(%{platform_module: module}), do: Modules.enabled?(module)
  defp endpoint_module_enabled?(_endpoint), do: true

  defp endpoint_catalog do
    [
      %{
        method: "GET",
        path: "/api/ext/v1/capabilities",
        summary: "Inspect available scopes, presets, and allowed endpoints",
        required_scopes: [],
        platform_module: nil
      },
      %{
        method: "GET",
        path: "/api/ext/v1/me",
        summary: "Inspect the authenticated user and token metadata",
        required_scopes: ["read:account", "write:account"],
        platform_module: nil
      },
      %{
        method: "GET",
        path: "/api/ext/v1/search",
        summary: "Search across resources allowed by the token",
        required_scopes: [
          "read:account",
          "read:email",
          "read:chat",
          "read:social",
          "read:contacts",
          "read:calendar"
        ],
        platform_module: nil
      },
      %{
        method: "GET",
        path: "/api/ext/v1/search/actions",
        summary: "List search actions allowed by the token",
        required_scopes: [
          "read:account",
          "read:email",
          "read:chat",
          "read:social",
          "read:contacts",
          "read:calendar"
        ],
        platform_module: nil
      },
      %{
        method: "POST",
        path: "/api/ext/v1/search/actions/execute",
        summary: "Execute a scoped action",
        required_scopes: [
          "read:account",
          "read:email",
          "read:chat",
          "read:social",
          "read:contacts",
          "read:calendar"
        ],
        platform_module: nil
      },
      %{
        method: "GET",
        path: "/api/ext/v1/email/messages",
        summary: "List email messages across the user's mailboxes",
        required_scopes: ["read:email", "write:email"],
        platform_module: :email
      },
      %{
        method: "GET",
        path: "/api/ext/v1/email/messages/:id",
        summary: "Get a single email message",
        required_scopes: ["read:email", "write:email"],
        platform_module: :email
      },
      %{
        method: "GET",
        path: "/api/ext/v1/chat/conversations",
        summary: "List chat conversations",
        required_scopes: ["read:chat", "write:chat"],
        platform_module: :chat
      },
      %{
        method: "GET",
        path: "/api/ext/v1/chat/conversations/:id",
        summary: "Get a chat conversation with recent messages",
        required_scopes: ["read:chat", "write:chat"],
        platform_module: :chat
      },
      %{
        method: "GET",
        path: "/api/ext/v1/chat/conversations/:id/messages",
        summary: "List messages for a chat conversation",
        required_scopes: ["read:chat", "write:chat"],
        platform_module: :chat
      },
      %{
        method: "GET",
        path: "/api/ext/v1/social/feed",
        summary: "List home or public social feed posts",
        required_scopes: ["read:social", "write:social"],
        platform_module: :social
      },
      %{
        method: "GET",
        path: "/api/ext/v1/social/posts/:id",
        summary: "Get a single visible social post",
        required_scopes: ["read:social", "write:social"],
        platform_module: :social
      },
      %{
        method: "GET",
        path: "/api/ext/v1/social/users/:user_id/posts",
        summary: "List visible posts for a specific user",
        required_scopes: ["read:social", "write:social"],
        platform_module: :social
      },
      %{
        method: "GET",
        path: "/api/ext/v1/contacts",
        summary: "List address book contacts",
        required_scopes: ["read:contacts", "write:contacts"],
        platform_module: nil
      },
      %{
        method: "GET",
        path: "/api/ext/v1/contacts/:id",
        summary: "Get a single address book contact",
        required_scopes: ["read:contacts", "write:contacts"],
        platform_module: nil
      },
      %{
        method: "GET",
        path: "/api/ext/v1/calendars",
        summary: "List calendars",
        required_scopes: ["read:calendar", "write:calendar"],
        platform_module: :email
      },
      %{
        method: "POST",
        path: "/api/ext/v1/calendars/:id/events",
        summary: "Create calendar events",
        required_scopes: ["write:calendar"],
        platform_module: :email
      },
      %{
        method: "GET",
        path: "/api/ext/v1/password-manager/entries",
        summary: "List encrypted vault entries",
        required_scopes: ["read:vault", "write:vault", "read:account", "write:account"],
        platform_module: :vault
      },
      %{
        method: "POST",
        path: "/api/ext/v1/password-manager/entries",
        summary: "Create encrypted vault entries",
        required_scopes: ["write:vault", "write:account"],
        platform_module: :vault
      },
      %{
        method: "POST",
        path: "/api/ext/v1/exports",
        summary: "Trigger data exports",
        required_scopes: ["export"],
        platform_module: nil
      },
      %{
        method: "GET",
        path: "/api/ext/v1/webhooks",
        summary: "List webhooks and recent deliveries",
        required_scopes: ["webhook"]
      },
      %{
        method: "POST",
        path: "/api/ext/v1/webhooks/:id/rotate-secret",
        summary: "Rotate a webhook signing secret",
        required_scopes: ["webhook"]
      },
      %{
        method: "POST",
        path: "/api/ext/v1/webhooks/:id/deliveries/:delivery_id/replay",
        summary: "Replay a webhook delivery",
        required_scopes: ["webhook"]
      }
    ]
  end
end
