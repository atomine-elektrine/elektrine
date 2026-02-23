defmodule Elektrine.Messaging.ArblargSDK do
  @moduledoc """
  Arblarg v1 reference SDK utilities.

  Provides deterministic signing, envelope validation, schema access,
  and retry helpers for interoperable multi-vendor implementations.
  """

  @protocol_name "arblarg"
  @protocol_id "arbp"
  @protocol_version "1.0"
  @protocol_label "arbp/1.0"
  @signature_algorithm "ed25519"
  @clock_skew_seconds 300

  @bootstrap_extension_urn "urn:arbp:ext:bootstrap:1"
  @bootstrap_server_upsert_event_type "urn:arbp:ext:bootstrap:1#server.upsert"

  @roles_extension_urn "urn:arbp:ext:roles:1"
  @roles_role_upsert_event_type "urn:arbp:ext:roles:1#role.upsert"
  @roles_role_assignment_upsert_event_type "urn:arbp:ext:roles:1#role.assignment.upsert"

  @permissions_extension_urn "urn:arbp:ext:permissions:1"
  @permissions_overwrite_upsert_event_type "urn:arbp:ext:permissions:1#overwrite.upsert"

  @threads_extension_urn "urn:arbp:ext:threads:1"
  @threads_thread_upsert_event_type "urn:arbp:ext:threads:1#thread.upsert"
  @threads_thread_archive_event_type "urn:arbp:ext:threads:1#thread.archive"

  @presence_extension_urn "urn:arbp:ext:presence:1"
  @presence_update_event_type "urn:arbp:ext:presence:1#presence.update"

  @moderation_extension_urn "urn:arbp:ext:moderation:1"
  @moderation_action_recorded_event_type "urn:arbp:ext:moderation:1#action.recorded"

  @dm_extension_urn "urn:arbp:ext:dm:1"
  @dm_message_create_event_type "urn:arbp:ext:dm:1#message.create"

  @core_event_types [
    "message.create",
    "message.update",
    "message.delete",
    "reaction.add",
    "reaction.remove",
    "read.receipt"
  ]

  @roles_event_types [
    @roles_role_upsert_event_type,
    @roles_role_assignment_upsert_event_type
  ]

  @permissions_event_types [
    @permissions_overwrite_upsert_event_type
  ]

  @threads_event_types [
    @threads_thread_upsert_event_type,
    @threads_thread_archive_event_type
  ]

  @presence_event_types [
    @presence_update_event_type
  ]

  @moderation_event_types [
    @moderation_action_recorded_event_type
  ]

  @dm_event_types [
    @dm_message_create_event_type
  ]

  @extension_event_types @roles_event_types ++
                           @permissions_event_types ++
                           @threads_event_types ++
                           @presence_event_types ++ @moderation_event_types ++ @dm_event_types

  @event_types [@bootstrap_server_upsert_event_type] ++
                 @core_event_types ++ @extension_event_types

  @extension_event_aliases %{
    "server.upsert" => @bootstrap_server_upsert_event_type,
    "role.upsert" => @roles_role_upsert_event_type,
    "role.assignment.upsert" => @roles_role_assignment_upsert_event_type,
    "permission.overwrite.upsert" => @permissions_overwrite_upsert_event_type,
    "thread.upsert" => @threads_thread_upsert_event_type,
    "thread.archive" => @threads_thread_archive_event_type,
    "presence.update" => @presence_update_event_type,
    "moderation.action.recorded" => @moderation_action_recorded_event_type,
    "dm.message.create" => @dm_message_create_event_type
  }

  @schema_name_aliases %{
    @bootstrap_server_upsert_event_type => "server.upsert",
    @roles_role_upsert_event_type => "role.upsert",
    @roles_role_assignment_upsert_event_type => "role.assignment.upsert",
    @permissions_overwrite_upsert_event_type => "permission.overwrite.upsert",
    @threads_thread_upsert_event_type => "thread.upsert",
    @threads_thread_archive_event_type => "thread.archive",
    @presence_update_event_type => "presence.update",
    @moderation_action_recorded_event_type => "moderation.action.recorded",
    @dm_message_create_event_type => "dm.message.create"
  }

  @schema_bindings %{
    "envelope" => "envelope",
    @bootstrap_server_upsert_event_type => "server.upsert",
    "server.upsert" => "server.upsert",
    "message.create" => "message.create",
    "message.update" => "message.update",
    "message.delete" => "message.delete",
    "reaction.add" => "reaction.add",
    "reaction.remove" => "reaction.remove",
    "read.receipt" => "read.receipt",
    @roles_role_upsert_event_type => "role.upsert",
    "role.upsert" => "role.upsert",
    @roles_role_assignment_upsert_event_type => "role.assignment.upsert",
    "role.assignment.upsert" => "role.assignment.upsert",
    @permissions_overwrite_upsert_event_type => "permission.overwrite.upsert",
    "permission.overwrite.upsert" => "permission.overwrite.upsert",
    @threads_thread_upsert_event_type => "thread.upsert",
    "thread.upsert" => "thread.upsert",
    @threads_thread_archive_event_type => "thread.archive",
    "thread.archive" => "thread.archive",
    @presence_update_event_type => "presence.update",
    "presence.update" => "presence.update",
    @moderation_action_recorded_event_type => "moderation.action.recorded",
    "moderation.action.recorded" => "moderation.action.recorded",
    @dm_message_create_event_type => "dm.message.create",
    "dm.message.create" => "dm.message.create"
  }

  @presence_statuses ["online", "idle", "dnd", "offline", "invisible"]
  @moderation_action_kinds ["timeout", "kick", "ban", "unban", "message_delete", "role_update"]

  @schemas %{
    "1.0" => %{
      "envelope" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/envelope",
        "title" => "Arblarg Event Envelope",
        "type" => "object",
        "required" => [
          "protocol",
          "protocol_id",
          "protocol_version",
          "event_type",
          "event_id",
          "origin_domain",
          "stream_id",
          "sequence",
          "sent_at",
          "idempotency_key",
          "payload",
          "signature"
        ],
        "properties" => %{
          "protocol" => %{"type" => "string", "const" => @protocol_name},
          "protocol_id" => %{"type" => "string", "const" => @protocol_id},
          "protocol_version" => %{"type" => "string", "const" => "1.0"},
          "event_type" => %{"type" => "string", "enum" => @event_types},
          "event_id" => %{"type" => "string", "minLength" => 1},
          "origin_domain" => %{"type" => "string", "minLength" => 1},
          "stream_id" => %{"type" => "string", "minLength" => 1},
          "sequence" => %{"type" => "integer", "minimum" => 1},
          "sent_at" => %{"type" => "string", "format" => "date-time"},
          "idempotency_key" => %{"type" => "string", "minLength" => 1},
          "payload" => %{"type" => "object"},
          "signature" => %{
            "type" => "object",
            "required" => ["algorithm", "key_id", "value"],
            "properties" => %{
              "algorithm" => %{"type" => "string", "const" => @signature_algorithm},
              "key_id" => %{"type" => "string", "minLength" => 1},
              "value" => %{"type" => "string", "minLength" => 1}
            }
          }
        }
      },
      "server.upsert" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/server.upsert",
        "title" => "Arblarg server.upsert payload",
        "type" => "object",
        "required" => ["server", "channels"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channels" => %{"type" => "array"}
        }
      },
      "message.create" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/message.create",
        "title" => "Arblarg message.create payload",
        "type" => "object",
        "required" => ["server", "channel", "message"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "message" => %{
            "type" => "object",
            "required" => ["id", "channel_id", "content"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1},
              "content" => %{"type" => "string"}
            }
          }
        }
      },
      "message.update" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/message.update",
        "title" => "Arblarg message.update payload",
        "type" => "object",
        "required" => ["server", "channel", "message"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "message" => %{
            "type" => "object",
            "required" => ["id", "channel_id", "content"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1},
              "content" => %{"type" => "string"},
              "edited_at" => %{"type" => "string", "format" => "date-time"}
            }
          }
        }
      },
      "message.delete" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/message.delete",
        "title" => "Arblarg message.delete payload",
        "type" => "object",
        "required" => ["server", "channel", "message_id"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "message_id" => %{"type" => "string", "minLength" => 1},
          "deleted_at" => %{"type" => "string", "format" => "date-time"}
        }
      },
      "reaction.add" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/reaction.add",
        "title" => "Arblarg reaction.add payload",
        "type" => "object",
        "required" => ["server", "channel", "message_id", "reaction"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "message_id" => %{"type" => "string", "minLength" => 1},
          "reaction" => %{
            "type" => "object",
            "required" => ["emoji", "actor"],
            "properties" => %{
              "emoji" => %{"type" => "string", "minLength" => 1},
              "actor" => %{"type" => "object"}
            }
          }
        }
      },
      "reaction.remove" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/reaction.remove",
        "title" => "Arblarg reaction.remove payload",
        "type" => "object",
        "required" => ["server", "channel", "message_id", "reaction"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "message_id" => %{"type" => "string", "minLength" => 1},
          "reaction" => %{
            "type" => "object",
            "required" => ["emoji", "actor"],
            "properties" => %{
              "emoji" => %{"type" => "string", "minLength" => 1},
              "actor" => %{"type" => "object"}
            }
          }
        }
      },
      "read.receipt" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/read.receipt",
        "title" => "Arblarg read.receipt payload",
        "type" => "object",
        "required" => ["server", "channel", "message_id", "actor", "read_at"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "message_id" => %{"type" => "string", "minLength" => 1},
          "actor" => %{"type" => "object"},
          "read_at" => %{"type" => "string", "format" => "date-time"}
        }
      },
      "role.upsert" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/role.upsert",
        "title" => "Arblarg role.upsert payload",
        "type" => "object",
        "required" => ["server", "channel", "role"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "role" => %{
            "type" => "object",
            "required" => ["id", "name", "permissions", "position"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "name" => %{"type" => "string", "minLength" => 1},
              "permissions" => %{"type" => "array", "items" => %{"type" => "string"}},
              "position" => %{"type" => "integer", "minimum" => 0},
              "color" => %{"type" => "string"},
              "hoist" => %{"type" => "boolean"},
              "mentionable" => %{"type" => "boolean"}
            }
          }
        }
      },
      "role.assignment.upsert" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/role.assignment.upsert",
        "title" => "Arblarg role.assignment.upsert payload",
        "type" => "object",
        "required" => ["server", "channel", "assignment"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "assignment" => %{
            "type" => "object",
            "required" => ["role_id", "target", "state"],
            "properties" => %{
              "role_id" => %{"type" => "string", "minLength" => 1},
              "target" => %{
                "type" => "object",
                "required" => ["type", "id"],
                "properties" => %{
                  "type" => %{"type" => "string", "enum" => ["user", "member"]},
                  "id" => %{"type" => "string", "minLength" => 1}
                }
              },
              "state" => %{"type" => "string", "enum" => ["assigned", "removed"]}
            }
          }
        }
      },
      "permission.overwrite.upsert" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/permission.overwrite.upsert",
        "title" => "Arblarg permission.overwrite.upsert payload",
        "type" => "object",
        "required" => ["server", "channel", "overwrite"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "overwrite" => %{
            "type" => "object",
            "required" => ["id", "target", "allow", "deny"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "target" => %{
                "type" => "object",
                "required" => ["type", "id"],
                "properties" => %{
                  "type" => %{"type" => "string", "enum" => ["role", "member"]},
                  "id" => %{"type" => "string", "minLength" => 1}
                }
              },
              "allow" => %{"type" => "array", "items" => %{"type" => "string"}},
              "deny" => %{"type" => "array", "items" => %{"type" => "string"}}
            }
          }
        }
      },
      "thread.upsert" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/thread.upsert",
        "title" => "Arblarg thread.upsert payload",
        "type" => "object",
        "required" => ["server", "channel", "thread"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "thread" => %{
            "type" => "object",
            "required" => ["id", "channel_id", "name", "state", "owner"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1},
              "name" => %{"type" => "string", "minLength" => 1},
              "state" => %{"type" => "string", "enum" => ["active", "archived", "locked"]},
              "owner" => %{"type" => "object"},
              "message_count" => %{"type" => "integer", "minimum" => 0},
              "member_count" => %{"type" => "integer", "minimum" => 0}
            }
          }
        }
      },
      "thread.archive" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/thread.archive",
        "title" => "Arblarg thread.archive payload",
        "type" => "object",
        "required" => ["server", "channel", "thread_id", "archived_at", "actor"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "thread_id" => %{"type" => "string", "minLength" => 1},
          "archived_at" => %{"type" => "string", "format" => "date-time"},
          "reason" => %{"type" => "string"},
          "actor" => %{"type" => "object"}
        }
      },
      "presence.update" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/presence.update",
        "title" => "Arblarg presence.update payload",
        "type" => "object",
        "required" => ["server", "presence"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "presence" => %{
            "type" => "object",
            "required" => ["actor", "status", "updated_at"],
            "properties" => %{
              "actor" => %{"type" => "object"},
              "status" => %{"type" => "string", "enum" => @presence_statuses},
              "updated_at" => %{"type" => "string", "format" => "date-time"},
              "activities" => %{"type" => "array", "items" => %{"type" => "object"}}
            }
          }
        }
      },
      "moderation.action.recorded" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/moderation.action.recorded",
        "title" => "Arblarg moderation.action.recorded payload",
        "type" => "object",
        "required" => ["server", "channel", "action"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "action" => %{
            "type" => "object",
            "required" => ["id", "kind", "target", "actor", "occurred_at"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "kind" => %{"type" => "string", "enum" => @moderation_action_kinds},
              "target" => %{"type" => "object"},
              "actor" => %{"type" => "object"},
              "occurred_at" => %{"type" => "string", "format" => "date-time"},
              "duration_seconds" => %{"type" => "integer", "minimum" => 0},
              "reason" => %{"type" => "string"}
            }
          }
        }
      },
      "dm.message.create" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arbp://schemas/1.0/dm.message.create",
        "title" => "Arblarg dm.message.create payload",
        "type" => "object",
        "required" => ["dm", "message"],
        "properties" => %{
          "dm" => %{
            "type" => "object",
            "required" => ["sender", "recipient"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "sender" => %{"type" => "object"},
              "recipient" => %{"type" => "object"}
            }
          },
          "message" => %{
            "type" => "object",
            "required" => ["id", "dm_id", "content", "sender"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "dm_id" => %{"type" => "string", "minLength" => 1},
              "content" => %{"type" => "string"},
              "message_type" => %{"type" => "string"},
              "media_urls" => %{"type" => "array"},
              "media_metadata" => %{"type" => "object"},
              "created_at" => %{"type" => "string", "format" => "date-time"},
              "sender" => %{"type" => "object"}
            }
          }
        }
      }
    }
  }

  def protocol_name, do: @protocol_name
  def protocol_id, do: @protocol_id
  def protocol_version, do: @protocol_version
  def protocol_label, do: @protocol_label
  def signature_algorithm, do: @signature_algorithm
  def clock_skew_seconds, do: @clock_skew_seconds
  def core_event_types, do: @core_event_types
  def extension_event_types, do: @extension_event_types
  def bootstrap_extension_urn, do: @bootstrap_extension_urn
  def bootstrap_server_upsert_event_type, do: @bootstrap_server_upsert_event_type
  def roles_extension_urn, do: @roles_extension_urn
  def permissions_extension_urn, do: @permissions_extension_urn
  def threads_extension_urn, do: @threads_extension_urn
  def presence_extension_urn, do: @presence_extension_urn
  def moderation_extension_urn, do: @moderation_extension_urn
  def dm_extension_urn, do: @dm_extension_urn
  def roles_event_types, do: @roles_event_types
  def permissions_event_types, do: @permissions_event_types
  def threads_event_types, do: @threads_event_types
  def presence_event_types, do: @presence_event_types
  def moderation_event_types, do: @moderation_event_types
  def dm_event_types, do: @dm_event_types
  def dm_message_create_event_type, do: @dm_message_create_event_type
  def schema_bindings, do: @schema_bindings

  def canonical_event_type(event_type) when is_binary(event_type) do
    Map.get(@extension_event_aliases, event_type, event_type)
  end

  def canonical_event_type(event_type), do: event_type

  def supported_event_types, do: @event_types

  def schema(version \\ @protocol_version, name)

  def schema(version, name) when is_binary(version) and is_binary(name) do
    schema_map = Map.get(@schemas, version, %{})
    Map.get(schema_map, name) || Map.get(schema_map, schema_name_alias(name))
  end

  def schema(_version, _name), do: nil

  def schema_names(version \\ @protocol_version) when is_binary(version) do
    @schemas
    |> Map.get(version, %{})
    |> Map.keys()
    |> Enum.sort()
  end

  def body_digest(body) when is_binary(body) do
    :crypto.hash(:sha256, body) |> Base.url_encode64(padding: false)
  end

  def body_digest(_), do: body_digest("")

  def canonical_request_signature_payload(
        domain,
        method,
        request_path,
        query_string,
        timestamp,
        content_digest \\ "",
        request_id \\ ""
      ) do
    [
      String.downcase(to_string(domain || "")),
      String.downcase(to_string(method || "")),
      canonical_path(request_path),
      canonical_query_string(query_string),
      to_string(timestamp || "") |> String.trim(),
      canonical_content_digest(content_digest),
      to_string(request_id || "") |> String.trim()
    ]
    |> Enum.join("\n")
  end

  def sign_payload(payload, private_key_material) when is_binary(payload) do
    with {:ok, private_key} <- normalize_private_key(private_key_material) do
      :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
      |> Base.url_encode64(padding: false)
    else
      _ -> ""
    end
  end

  def verify_payload_signature(payload, public_key_material, signature)
      when is_binary(payload) and is_binary(signature) do
    with {:ok, public_key} <- normalize_public_key(public_key_material),
         {:ok, raw_signature} <- Base.url_decode64(String.trim(signature), padding: false) do
      :crypto.verify(:eddsa, :none, payload, raw_signature, [public_key, :ed25519])
    else
      _ -> false
    end
  end

  def verify_payload_signature(_payload, _public_key_material, _signature), do: false

  def valid_timestamp?(timestamp, skew_seconds \\ @clock_skew_seconds)

  def valid_timestamp?(timestamp, skew_seconds) when is_binary(timestamp) do
    case Integer.parse(timestamp) do
      {ts, ""} when is_integer(skew_seconds) and skew_seconds >= 0 ->
        abs(System.system_time(:second) - ts) <= skew_seconds

      _ ->
        false
    end
  end

  def valid_timestamp?(_timestamp, _skew_seconds), do: false

  def sign_event_envelope(envelope, key_id, private_key_material) when is_map(envelope) do
    signature_value =
      envelope
      |> canonical_event_signature_payload()
      |> sign_payload(private_key_material)

    Map.put(envelope, "signature", %{
      "algorithm" => @signature_algorithm,
      "key_id" => to_string(key_id || ""),
      "value" => signature_value
    })
  end

  def verify_event_envelope_signature(envelope, key_lookup_fun)
      when is_map(envelope) and is_function(key_lookup_fun, 1) do
    signature = envelope["signature"] || %{}
    key_id = signature["key_id"]
    algorithm = signature["algorithm"]
    value = signature["value"]

    if is_binary(key_id) and is_binary(value) and algorithm == @signature_algorithm do
      envelope_without_signature = Map.delete(envelope, "signature")

      signing_payloads =
        [
          canonical_event_signature_payload(envelope_without_signature),
          legacy_canonical_event_signature_payload(envelope_without_signature)
        ]
        |> Enum.uniq()

      verification_materials = key_lookup_fun.(key_id) |> List.wrap()

      Enum.any?(signing_payloads, fn signing_payload ->
        Enum.any?(verification_materials, fn public_key_material ->
          verify_payload_signature(signing_payload, public_key_material, value)
        end)
      end)
    else
      false
    end
  end

  def verify_event_envelope_signature(_, _), do: false

  def canonical_event_payload_for_signing(envelope) when is_map(envelope) do
    envelope
    |> Map.delete("signature")
    |> canonical_event_signature_payload()
  end

  def canonical_event_payload_for_signing(_), do: ""

  def validate_event_envelope(envelope) when is_map(envelope) do
    protocol_id = envelope["protocol_id"] || legacy_protocol_id(envelope)
    protocol_name = envelope["protocol"] || legacy_protocol_name(envelope)
    protocol_version = envelope["protocol_version"] || legacy_protocol_version(envelope)
    event_type = canonical_event_type(envelope["event_type"])
    payload = envelope["payload"] || envelope["data"] || %{}
    idempotency_key = envelope["idempotency_key"] || envelope["event_id"]

    cond do
      protocol_id != @protocol_id ->
        {:error, :unsupported_protocol}

      protocol_name != @protocol_name ->
        {:error, :unsupported_protocol}

      protocol_version != @protocol_version ->
        {:error, :unsupported_version}

      event_type not in @event_types ->
        {:error, :unsupported_event_type}

      !non_empty_binary?(envelope["event_id"]) ->
        {:error, :invalid_event_id}

      !non_empty_binary?(envelope["origin_domain"]) ->
        {:error, :invalid_origin_domain}

      !non_empty_binary?(envelope["stream_id"]) ->
        {:error, :invalid_stream_id}

      parse_int(envelope["sequence"], 0) <= 0 ->
        {:error, :invalid_sequence}

      !non_empty_binary?(idempotency_key) ->
        {:error, :invalid_idempotency_key}

      !valid_iso8601?(envelope["sent_at"]) ->
        {:error, :invalid_sent_at}

      !is_map(payload) ->
        {:error, :invalid_event_payload}

      Map.has_key?(envelope, "signature") and !valid_signature_map?(envelope["signature"]) ->
        {:error, :invalid_signature}

      true ->
        validate_event_payload(event_type, payload)
    end
  end

  def validate_event_envelope(_), do: {:error, :invalid_payload}

  def validate_event_payload("message.create", payload),
    do: validate_message_upsert_payload(payload)

  def validate_event_payload("message.update", payload),
    do: validate_message_upsert_payload(payload)

  def validate_event_payload(@bootstrap_server_upsert_event_type, payload) do
    cond do
      !is_map(payload) -> {:error, :invalid_event_payload}
      !is_map(payload["server"]) -> {:error, :invalid_event_payload}
      !is_list(payload["channels"] || []) -> {:error, :invalid_event_payload}
      true -> :ok
    end
  end

  def validate_event_payload("server.upsert", payload),
    do: validate_event_payload(@bootstrap_server_upsert_event_type, payload)

  def validate_event_payload("message.delete", payload) do
    cond do
      !is_map(payload) -> {:error, :invalid_event_payload}
      !is_map(payload["server"]) -> {:error, :invalid_event_payload}
      !is_map(payload["channel"]) -> {:error, :invalid_event_payload}
      !non_empty_binary?(payload["message_id"]) -> {:error, :invalid_event_payload}
      true -> :ok
    end
  end

  def validate_event_payload("reaction.add", payload), do: validate_reaction_payload(payload)
  def validate_event_payload("reaction.remove", payload), do: validate_reaction_payload(payload)

  def validate_event_payload("read.receipt", payload) do
    cond do
      !is_map(payload) -> {:error, :invalid_event_payload}
      !is_map(payload["server"]) -> {:error, :invalid_event_payload}
      !is_map(payload["channel"]) -> {:error, :invalid_event_payload}
      !non_empty_binary?(payload["message_id"]) -> {:error, :invalid_event_payload}
      !is_map(payload["actor"]) -> {:error, :invalid_event_payload}
      !valid_iso8601?(payload["read_at"]) -> {:error, :invalid_event_payload}
      true -> :ok
    end
  end

  def validate_event_payload(@roles_role_upsert_event_type, payload),
    do: validate_role_upsert_payload(payload)

  def validate_event_payload("role.upsert", payload),
    do: validate_event_payload(@roles_role_upsert_event_type, payload)

  def validate_event_payload(@roles_role_assignment_upsert_event_type, payload),
    do: validate_role_assignment_upsert_payload(payload)

  def validate_event_payload("role.assignment.upsert", payload),
    do: validate_event_payload(@roles_role_assignment_upsert_event_type, payload)

  def validate_event_payload(@permissions_overwrite_upsert_event_type, payload),
    do: validate_permission_overwrite_upsert_payload(payload)

  def validate_event_payload("permission.overwrite.upsert", payload),
    do: validate_event_payload(@permissions_overwrite_upsert_event_type, payload)

  def validate_event_payload(@threads_thread_upsert_event_type, payload),
    do: validate_thread_upsert_payload(payload)

  def validate_event_payload("thread.upsert", payload),
    do: validate_event_payload(@threads_thread_upsert_event_type, payload)

  def validate_event_payload(@threads_thread_archive_event_type, payload),
    do: validate_thread_archive_payload(payload)

  def validate_event_payload("thread.archive", payload),
    do: validate_event_payload(@threads_thread_archive_event_type, payload)

  def validate_event_payload(@presence_update_event_type, payload),
    do: validate_presence_update_payload(payload)

  def validate_event_payload("presence.update", payload),
    do: validate_event_payload(@presence_update_event_type, payload)

  def validate_event_payload(@moderation_action_recorded_event_type, payload),
    do: validate_moderation_action_recorded_payload(payload)

  def validate_event_payload("moderation.action.recorded", payload),
    do: validate_event_payload(@moderation_action_recorded_event_type, payload)

  def validate_event_payload(@dm_message_create_event_type, payload),
    do: validate_dm_message_create_payload(payload)

  def validate_event_payload("dm.message.create", payload),
    do: validate_event_payload(@dm_message_create_event_type, payload)

  def validate_event_payload(_event_type, _payload), do: {:error, :unsupported_event_type}

  def with_retries(fun, opts \\ []) when is_function(fun, 0) do
    attempts = Keyword.get(opts, :attempts, 3) |> max(1)
    base_backoff_ms = Keyword.get(opts, :base_backoff_ms, 250) |> max(1)
    jitter_ms = Keyword.get(opts, :jitter_ms, 50) |> max(0)

    do_with_retries(fun, attempts, base_backoff_ms, jitter_ms)
  end

  def derive_keypair_from_secret(secret) when is_binary(secret) do
    seed = :crypto.hash(:sha256, secret) |> binary_part(0, 32)
    :crypto.generate_key(:eddsa, :ed25519, seed)
  end

  defp do_with_retries(fun, attempts_left, base_backoff_ms, jitter_ms) do
    case safe_call(fun) do
      {:ok, _} = ok ->
        ok

      {:error, _reason} = error when attempts_left <= 1 ->
        error

      {:error, _reason} ->
        retry_index = attempts_left - 1
        backoff_ms = trunc(min(base_backoff_ms * :math.pow(2, retry_index - 1), 5_000))
        jitter = if jitter_ms > 0, do: :rand.uniform(jitter_ms), else: 0
        Process.sleep(backoff_ms + jitter)
        do_with_retries(fun, attempts_left - 1, base_backoff_ms, jitter_ms)
    end
  end

  defp safe_call(fun) do
    try do
      case fun.() do
        {:ok, _} = ok -> ok
        {:error, _} = error -> error
        other -> {:ok, other}
      end
    rescue
      error -> {:error, {:exception, error}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp normalize_private_key(key) when is_binary(key) and byte_size(key) == 32,
    do: {:ok, key}

  defp normalize_private_key(%{private_key: key}), do: normalize_private_key(key)
  defp normalize_private_key(%{secret: secret}), do: normalize_private_key(secret)

  defp normalize_private_key(key) when is_binary(key) do
    trimmed = String.trim(key)

    cond do
      trimmed == "" ->
        {:error, :invalid_private_key}

      true ->
        case decode_32_byte_key(trimmed) do
          {:ok, decoded} ->
            {:ok, decoded}

          :error ->
            {_public_key, private_key} = derive_keypair_from_secret(trimmed)
            {:ok, private_key}
        end
    end
  end

  defp normalize_private_key(_), do: {:error, :invalid_private_key}

  defp normalize_public_key(key) when is_binary(key) and byte_size(key) == 32,
    do: {:ok, key}

  defp normalize_public_key(%{public_key: key}), do: normalize_public_key(key)
  defp normalize_public_key(%{secret: secret}), do: normalize_public_key(secret)

  defp normalize_public_key(key) when is_binary(key) do
    trimmed = String.trim(key)

    cond do
      trimmed == "" ->
        {:error, :invalid_public_key}

      true ->
        case decode_32_byte_key(trimmed) do
          {:ok, decoded} ->
            {:ok, decoded}

          :error ->
            {public_key, _private_key} = derive_keypair_from_secret(trimmed)
            {:ok, public_key}
        end
    end
  end

  defp normalize_public_key(_), do: {:error, :invalid_public_key}

  defp decode_32_byte_key(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
      _ -> decode_32_byte_key_standard(encoded)
    end
  end

  defp decode_32_byte_key_standard(encoded) do
    case Base.decode64(encoded) do
      {:ok, raw} when byte_size(raw) == 32 -> {:ok, raw}
      _ -> :error
    end
  end

  defp validate_message_upsert_payload(payload) do
    message = if is_map(payload), do: payload["message"], else: nil

    cond do
      !is_map(payload) -> {:error, :invalid_event_payload}
      !is_map(payload["server"]) -> {:error, :invalid_event_payload}
      !is_map(payload["channel"]) -> {:error, :invalid_event_payload}
      !is_map(message) -> {:error, :invalid_event_payload}
      !non_empty_binary?(message["id"]) -> {:error, :invalid_event_payload}
      !non_empty_binary?(message["channel_id"]) -> {:error, :invalid_event_payload}
      !is_binary(message["content"] || "") -> {:error, :invalid_event_payload}
      true -> :ok
    end
  end

  defp validate_reaction_payload(payload) do
    reaction = if is_map(payload), do: payload["reaction"], else: nil

    cond do
      !is_map(payload) -> {:error, :invalid_event_payload}
      !is_map(payload["server"]) -> {:error, :invalid_event_payload}
      !is_map(payload["channel"]) -> {:error, :invalid_event_payload}
      !non_empty_binary?(payload["message_id"]) -> {:error, :invalid_event_payload}
      !is_map(reaction) -> {:error, :invalid_event_payload}
      !non_empty_binary?(reaction["emoji"]) -> {:error, :invalid_event_payload}
      !is_map(reaction["actor"]) -> {:error, :invalid_event_payload}
      true -> :ok
    end
  end

  defp validate_role_upsert_payload(payload) do
    role = if is_map(payload), do: payload["role"], else: nil

    cond do
      !is_map(payload) -> {:error, :invalid_event_payload}
      !is_map(payload["server"]) -> {:error, :invalid_event_payload}
      !is_map(payload["channel"]) -> {:error, :invalid_event_payload}
      !is_map(role) -> {:error, :invalid_event_payload}
      !non_empty_binary?(role["id"]) -> {:error, :invalid_event_payload}
      !non_empty_binary?(role["name"]) -> {:error, :invalid_event_payload}
      !is_integer(role["position"]) or role["position"] < 0 -> {:error, :invalid_event_payload}
      !valid_string_list?(role["permissions"]) -> {:error, :invalid_event_payload}
      true -> :ok
    end
  end

  defp validate_role_assignment_upsert_payload(payload) do
    assignment = if is_map(payload), do: payload["assignment"], else: nil

    cond do
      !is_map(payload) -> {:error, :invalid_event_payload}
      !is_map(payload["server"]) -> {:error, :invalid_event_payload}
      !is_map(payload["channel"]) -> {:error, :invalid_event_payload}
      !is_map(assignment) -> {:error, :invalid_event_payload}
      !non_empty_binary?(assignment["role_id"]) -> {:error, :invalid_event_payload}
      !valid_target?(assignment["target"], ["user", "member"]) -> {:error, :invalid_event_payload}
      assignment["state"] not in ["assigned", "removed"] -> {:error, :invalid_event_payload}
      true -> :ok
    end
  end

  defp validate_permission_overwrite_upsert_payload(payload) do
    overwrite = if is_map(payload), do: payload["overwrite"], else: nil

    cond do
      !is_map(payload) -> {:error, :invalid_event_payload}
      !is_map(payload["server"]) -> {:error, :invalid_event_payload}
      !is_map(payload["channel"]) -> {:error, :invalid_event_payload}
      !is_map(overwrite) -> {:error, :invalid_event_payload}
      !non_empty_binary?(overwrite["id"]) -> {:error, :invalid_event_payload}
      !valid_target?(overwrite["target"], ["role", "member"]) -> {:error, :invalid_event_payload}
      !valid_string_list?(overwrite["allow"]) -> {:error, :invalid_event_payload}
      !valid_string_list?(overwrite["deny"]) -> {:error, :invalid_event_payload}
      true -> :ok
    end
  end

  defp validate_thread_upsert_payload(payload) do
    thread = if is_map(payload), do: payload["thread"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !is_map(payload["server"]) ->
        {:error, :invalid_event_payload}

      !is_map(payload["channel"]) ->
        {:error, :invalid_event_payload}

      !is_map(thread) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(thread["id"]) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(thread["channel_id"]) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(thread["name"]) ->
        {:error, :invalid_event_payload}

      thread["state"] not in ["active", "archived", "locked"] ->
        {:error, :invalid_event_payload}

      !is_map(thread["owner"]) ->
        {:error, :invalid_event_payload}

      !valid_non_negative_integer_or_nil?(thread["message_count"]) ->
        {:error, :invalid_event_payload}

      !valid_non_negative_integer_or_nil?(thread["member_count"]) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp validate_thread_archive_payload(payload) do
    cond do
      !is_map(payload) -> {:error, :invalid_event_payload}
      !is_map(payload["server"]) -> {:error, :invalid_event_payload}
      !is_map(payload["channel"]) -> {:error, :invalid_event_payload}
      !non_empty_binary?(payload["thread_id"]) -> {:error, :invalid_event_payload}
      !valid_iso8601?(payload["archived_at"]) -> {:error, :invalid_event_payload}
      !is_map(payload["actor"]) -> {:error, :invalid_event_payload}
      true -> :ok
    end
  end

  defp validate_presence_update_payload(payload) do
    presence = if is_map(payload), do: payload["presence"], else: nil
    activities = if is_map(presence), do: presence["activities"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !is_map(payload["server"]) ->
        {:error, :invalid_event_payload}

      !is_map(presence) ->
        {:error, :invalid_event_payload}

      !is_map(presence["actor"]) ->
        {:error, :invalid_event_payload}

      presence["status"] not in @presence_statuses ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(presence["updated_at"]) ->
        {:error, :invalid_event_payload}

      !is_nil(activities) and (!is_list(activities) or Enum.any?(activities, &(not is_map(&1)))) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp validate_moderation_action_recorded_payload(payload) do
    action = if is_map(payload), do: payload["action"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !is_map(payload["server"]) ->
        {:error, :invalid_event_payload}

      !is_map(payload["channel"]) ->
        {:error, :invalid_event_payload}

      !is_map(action) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(action["id"]) ->
        {:error, :invalid_event_payload}

      action["kind"] not in @moderation_action_kinds ->
        {:error, :invalid_event_payload}

      !is_map(action["target"]) ->
        {:error, :invalid_event_payload}

      !is_map(action["actor"]) ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(action["occurred_at"]) ->
        {:error, :invalid_event_payload}

      !valid_non_negative_integer_or_nil?(action["duration_seconds"]) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp validate_dm_message_create_payload(payload) do
    dm = if is_map(payload), do: payload["dm"], else: nil
    message = if is_map(payload), do: payload["message"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !is_map(dm) ->
        {:error, :invalid_event_payload}

      !is_map(message) ->
        {:error, :invalid_event_payload}

      !is_map(dm["sender"]) ->
        {:error, :invalid_event_payload}

      !is_map(dm["recipient"]) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(message["id"]) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(message["dm_id"]) ->
        {:error, :invalid_event_payload}

      !is_binary(message["content"] || "") ->
        {:error, :invalid_event_payload}

      !is_map(message["sender"]) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp valid_target?(target, allowed_types) when is_map(target) and is_list(allowed_types) do
    non_empty_binary?(target["id"]) and target["type"] in allowed_types
  end

  defp valid_target?(_target, _allowed_types), do: false

  defp valid_string_list?(values) when is_list(values) do
    Enum.all?(values, &non_empty_binary?/1)
  end

  defp valid_string_list?(_values), do: false

  defp valid_non_negative_integer_or_nil?(nil), do: true
  defp valid_non_negative_integer_or_nil?(value) when is_integer(value) and value >= 0, do: true
  defp valid_non_negative_integer_or_nil?(_), do: false

  defp legacy_protocol_version(envelope) do
    case envelope["version"] do
      1 -> @protocol_version
      "1" -> @protocol_version
      _ -> nil
    end
  end

  defp legacy_protocol_id(_envelope), do: @protocol_id

  defp legacy_protocol_name(envelope) do
    case envelope["protocol"] do
      value when is_binary(value) -> value
      _ -> @protocol_name
    end
  end

  defp valid_signature_map?(signature) when is_map(signature) do
    signature["algorithm"] == @signature_algorithm and non_empty_binary?(signature["key_id"]) and
      non_empty_binary?(signature["value"])
  end

  defp valid_signature_map?(_), do: false

  defp valid_iso8601?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _dt, _offset} -> true
      _ -> false
    end
  end

  defp valid_iso8601?(_), do: false

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp non_empty_binary?(value) when is_binary(value) do
    String.trim(value) != ""
  end

  defp non_empty_binary?(_), do: false

  defp canonical_event_signature_payload(envelope) when is_map(envelope) do
    canonical_event_signature_payload(envelope, @protocol_id)
  end

  defp legacy_canonical_event_signature_payload(envelope) when is_map(envelope) do
    canonical_event_signature_payload(envelope, @protocol_name)
  end

  defp canonical_event_signature_payload(envelope, protocol_identifier) when is_map(envelope) do
    payload = envelope["payload"] || envelope["data"] || %{}
    idempotency_key = envelope["idempotency_key"] || envelope["event_id"]

    [
      protocol_identifier,
      to_string(envelope["protocol_version"] || legacy_protocol_version(envelope) || ""),
      to_string(envelope["event_type"] || ""),
      to_string(envelope["event_id"] || ""),
      to_string(envelope["origin_domain"] || ""),
      to_string(envelope["stream_id"] || ""),
      to_string(parse_int(envelope["sequence"], 0)),
      to_string(envelope["sent_at"] || ""),
      to_string(idempotency_key || ""),
      canonical_json(payload)
    ]
    |> Enum.join("\n")
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.map(fn {key, val} -> {to_string(key), val} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, val} ->
      Jason.encode!(key) <> ":" <> canonical_json(val)
    end)
    |> then(fn body -> "{" <> body <> "}" end)
  end

  defp canonical_json(value) when is_list(value) do
    value
    |> Enum.map_join(",", &canonical_json/1)
    |> then(fn body -> "[" <> body <> "]" end)
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp canonical_path(nil), do: "/"

  defp canonical_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> "/"
      String.starts_with?(trimmed, "/") -> trimmed
      true -> "/" <> trimmed
    end
  end

  defp canonical_path(path), do: canonical_path(to_string(path))

  defp canonical_query_string(nil), do: ""
  defp canonical_query_string(query) when is_binary(query), do: String.trim(query)
  defp canonical_query_string(query), do: to_string(query)

  defp canonical_content_digest(nil), do: body_digest("")

  defp canonical_content_digest(content_digest) when is_binary(content_digest) do
    case String.trim(content_digest) do
      "" -> body_digest("")
      value -> value
    end
  end

  defp canonical_content_digest(content_digest),
    do: canonical_content_digest(to_string(content_digest))

  defp schema_name_alias(name), do: Map.get(@schema_name_aliases, name, name)
end
