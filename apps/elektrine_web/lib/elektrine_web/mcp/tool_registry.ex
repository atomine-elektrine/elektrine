defmodule ElektrineWeb.MCP.ToolRegistry do
  @moduledoc """
  Scope-aware MCP tool registry for Elektrine external integrations.
  """

  alias Elektrine.Developer.ApiToken
  alias ElektrineWeb.MCP.Tools

  @tools [
    %{
      name: "elektrine.capabilities",
      description: "Inspect authenticated MCP capabilities, token scopes, and visible tools.",
      required_scopes: [],
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.capabilities/2
    },
    %{
      name: "account.me",
      description: "Read the authenticated user's account profile and token metadata.",
      required_scopes: ["read:account", "write:account"],
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.account_me/2
    },
    %{
      name: "elektrine.search",
      description: "Search across account data allowed by the token's read scopes.",
      required_scopes: [
        "read:account",
        "read:email",
        "read:chat",
        "read:social",
        "read:contacts",
        "read:calendar"
      ],
      input_schema: %{
        "type" => "object",
        "required" => ["query"],
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Search query."},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 25}
        },
        "additionalProperties" => false
      },
      handler: &Tools.search/2
    },
    %{
      name: "elektrine.actions.list",
      description: "List command-palette actions available to the token.",
      required_scopes: [],
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.actions_list/2
    },
    %{
      name: "elektrine.actions.execute",
      description: "Execute a command-palette action if the token has the required scopes.",
      required_scopes: [],
      input_schema: %{
        "type" => "object",
        "required" => ["command"],
        "properties" => %{
          "command" => %{"type" => "string", "description" => "Action command or id."}
        },
        "additionalProperties" => false
      },
      handler: &Tools.actions_execute/2
    },
    %{
      name: "email.messages.list",
      description: "List email messages visible to the authenticated user.",
      required_scopes: ["read:email", "write:email"],
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
          "offset" => %{"type" => "integer", "minimum" => 0},
          "folder" => %{
            "type" => "string",
            "enum" => [
              "all",
              "inbox",
              "feed",
              "ledger",
              "stack",
              "reply_later",
              "sent",
              "drafts",
              "spam",
              "trash",
              "archived"
            ]
          },
          "mailbox_id" => %{"type" => ["integer", "string"]}
        },
        "additionalProperties" => false
      },
      handler: &Tools.email_messages_list/2
    },
    %{
      name: "email.messages.search",
      description: "Search email messages in the authenticated user's mailbox.",
      required_scopes: ["read:email", "write:email"],
      input_schema: %{
        "type" => "object",
        "required" => ["query"],
        "properties" => %{
          "query" => %{"type" => "string"},
          "page" => %{"type" => "integer", "minimum" => 1},
          "per_page" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
        },
        "additionalProperties" => false
      },
      handler: &Tools.email_messages_search/2
    },
    %{
      name: "email.messages.get",
      description: "Read one email message by id.",
      required_scopes: ["read:email", "write:email"],
      input_schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{"id" => %{"type" => ["integer", "string"]}},
        "additionalProperties" => false
      },
      handler: &Tools.email_messages_get/2
    },
    %{
      name: "email.messages.send",
      description: "Send an email from the authenticated user's mailbox.",
      required_scopes: ["write:email"],
      input_schema: %{
        "type" => "object",
        "required" => ["to"],
        "properties" => %{
          "to" => %{"type" => "string"},
          "cc" => %{"type" => "string"},
          "bcc" => %{"type" => "string"},
          "reply_to" => %{"type" => "string"},
          "subject" => %{"type" => "string"},
          "text_body" => %{"type" => "string"},
          "body" => %{"type" => "string"},
          "html_body" => %{"type" => "string"},
          "encryption_mode" => %{"type" => "string"}
        },
        "additionalProperties" => false
      },
      handler: &Tools.email_messages_send/2
    },
    %{
      name: "email.messages.update",
      description: "Update simple email state such as read, archived, spam, trash, or category.",
      required_scopes: ["write:email"],
      input_schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{
          "id" => %{"type" => ["integer", "string"]},
          "read" => %{"type" => "boolean"},
          "archived" => %{"type" => "boolean"},
          "spam" => %{"type" => "boolean"},
          "deleted" => %{"type" => "boolean"},
          "category" => %{"type" => "string", "enum" => ["inbox", "feed", "ledger", "stack"]}
        },
        "additionalProperties" => false
      },
      handler: &Tools.email_messages_update/2
    },
    %{
      name: "kairo.projects.list",
      description: "List Kairo projects.",
      required_scopes: ["read:kairo", "write:kairo"],
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "status" => %{"type" => "string", "description" => "Optional project status filter."}
        },
        "additionalProperties" => false
      },
      handler: &Tools.kairo_projects_list/2
    },
    %{
      name: "kairo.sources.list",
      description: "List Kairo sources with optional filters.",
      required_scopes: ["read:kairo", "write:kairo"],
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
          "offset" => %{"type" => "integer", "minimum" => 0},
          "status" => %{"type" => "string"},
          "source_type" => %{"type" => "string"},
          "project_id" => %{"type" => ["integer", "string"]}
        },
        "additionalProperties" => false
      },
      handler: &Tools.kairo_sources_list/2
    },
    %{
      name: "kairo.sources.get",
      description: "Read one Kairo source including content when available.",
      required_scopes: ["read:kairo", "write:kairo"],
      input_schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{"id" => %{"type" => ["integer", "string"]}},
        "additionalProperties" => false
      },
      handler: &Tools.kairo_sources_get/2
    },
    %{
      name: "kairo.sources.create",
      description: "Create or ingest a Kairo source such as a note, URL, or captured page.",
      required_scopes: ["write:kairo"],
      input_schema: %{
        "type" => "object",
        "required" => ["source_type"],
        "properties" => %{
          "source_type" => %{"type" => "string"},
          "title" => %{"type" => "string"},
          "url" => %{"type" => "string"},
          "content" => %{"type" => "string"},
          "content_format" => %{"type" => "string"},
          "encrypted" => %{
            "type" => "boolean",
            "description" => "Whether content is a client-encrypted payload."
          },
          "encrypted_content" => %{
            "type" => "object",
            "description" => "Client-encrypted AES-GCM content envelope."
          },
          "project_id" => %{"type" => ["integer", "string"]},
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
          "metadata" => %{"type" => "object"}
        },
        "additionalProperties" => true
      },
      handler: &Tools.kairo_sources_create/2
    },
    %{
      name: "kairo.sources.retry",
      description: "Retry ingestion for a failed Kairo URL source.",
      required_scopes: ["write:kairo"],
      input_schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{"id" => %{"type" => ["integer", "string"]}},
        "additionalProperties" => false
      },
      handler: &Tools.kairo_sources_retry/2
    },
    %{
      name: "nerve.entries.list",
      description: "List encrypted Nerve entries. Secret values remain ciphertext.",
      required_scopes: ["read:nerve", "write:nerve"],
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      handler: &Tools.nerve_entries_list/2
    },
    %{
      name: "nerve.entries.get",
      description: "Read one encrypted Nerve entry including ciphertext envelopes.",
      required_scopes: ["read:nerve", "write:nerve"],
      input_schema: %{
        "type" => "object",
        "required" => ["id"],
        "properties" => %{"id" => %{"type" => ["integer", "string"]}},
        "additionalProperties" => false
      },
      handler: &Tools.nerve_entries_get/2
    },
    %{
      name: "nerve.entries.create",
      description: "Create an encrypted Nerve entry from already-encrypted payload fields.",
      required_scopes: ["write:nerve"],
      input_schema: %{
        "type" => "object",
        "required" => ["title"],
        "properties" => %{
          "title" => %{"type" => "string"},
          "login_username" => %{"type" => "string"},
          "website" => %{"type" => "string"},
          "encrypted_metadata" => %{"type" => "object"},
          "encrypted_password" => %{"type" => "object"},
          "encrypted_notes" => %{"type" => "object"}
        },
        "additionalProperties" => true
      },
      handler: &Tools.nerve_entries_create/2
    }
  ]

  def all_tools, do: @tools

  def available_tools(conn) do
    conn
    |> visible_tools()
    |> Enum.map(&tool_descriptor/1)
  end

  def call(conn, name, arguments) when is_binary(name) do
    case Enum.find(@tools, &(&1.name == name)) do
      nil ->
        {:error, :unknown_tool}

      tool ->
        if tool_allowed?(conn, tool) do
          tool.handler.(conn, normalize_arguments(arguments))
        else
          {:error, :insufficient_scope, tool.required_scopes}
        end
    end
  end

  def call(_conn, _name, _arguments), do: {:error, :unknown_tool}

  def token_scopes(conn) do
    case conn.assigns[:api_token] do
      %ApiToken{scopes: scopes} when is_list(scopes) -> scopes
      %{scopes: scopes} when is_list(scopes) -> scopes
      _ -> []
    end
  end

  defp visible_tools(conn), do: Enum.filter(@tools, &tool_allowed?(conn, &1))

  defp tool_allowed?(_conn, %{required_scopes: []}), do: true

  defp tool_allowed?(conn, %{required_scopes: scopes}) do
    case conn.assigns[:api_token] do
      %ApiToken{} = token ->
        ApiToken.has_any_scope?(token, scopes)

      %{scopes: token_scopes} when is_list(token_scopes) ->
        Enum.any?(scopes, &(&1 in token_scopes))

      _ ->
        false
    end
  end

  defp tool_descriptor(tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => tool.input_schema,
      "annotations" => %{
        "requiredScopes" => tool.required_scopes
      }
    }
  end

  defp normalize_arguments(arguments) when is_map(arguments), do: arguments
  defp normalize_arguments(_arguments), do: %{}
end
