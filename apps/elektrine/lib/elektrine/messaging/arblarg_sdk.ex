defmodule Elektrine.Messaging.ArblargSDK do
  @moduledoc """
  Arblarg v1 reference SDK utilities.

  Provides deterministic signing, envelope validation, schema access,
  and retry helpers for interoperable multi-vendor implementations.
  """

  @protocol_name "arblarg"
  @protocol_id "arblarg"
  @protocol_version "1.0"
  @protocol_label "arblarg/1.0"
  @signature_algorithm "ed25519"
  @clock_skew_seconds 300

  @bootstrap_extension_urn "urn:arblarg:ext:bootstrap:1"
  @bootstrap_server_upsert_event_type "urn:arblarg:ext:bootstrap:1#server.upsert"

  @roles_extension_urn "urn:arblarg:ext:roles:1"
  @roles_role_upsert_event_type "urn:arblarg:ext:roles:1#role.upsert"
  @roles_role_assignment_upsert_event_type "urn:arblarg:ext:roles:1#role.assignment.upsert"

  @permissions_extension_urn "urn:arblarg:ext:permissions:1"
  @permissions_overwrite_upsert_event_type "urn:arblarg:ext:permissions:1#overwrite.upsert"

  @threads_extension_urn "urn:arblarg:ext:threads:1"
  @threads_thread_upsert_event_type "urn:arblarg:ext:threads:1#thread.upsert"
  @threads_thread_archive_event_type "urn:arblarg:ext:threads:1#thread.archive"

  @presence_extension_urn "urn:arblarg:ext:presence:1"
  @presence_update_event_type "urn:arblarg:ext:presence:1#presence.update"
  @typing_start_event_type "urn:arblarg:ext:presence:1#typing.start"
  @typing_stop_event_type "urn:arblarg:ext:presence:1#typing.stop"

  @moderation_extension_urn "urn:arblarg:ext:moderation:1"
  @moderation_action_recorded_event_type "urn:arblarg:ext:moderation:1#action.recorded"

  @dm_extension_urn "urn:arblarg:ext:dm:1"
  @dm_message_create_event_type "urn:arblarg:ext:dm:1#message.create"

  @voice_extension_urn "urn:arblarg:ext:voice:1"
  @voice_dm_call_invite_event_type "urn:arblarg:ext:voice:1#dm.call.invite"
  @voice_dm_call_accept_event_type "urn:arblarg:ext:voice:1#dm.call.accept"
  @voice_dm_call_reject_event_type "urn:arblarg:ext:voice:1#dm.call.reject"
  @voice_dm_call_end_event_type "urn:arblarg:ext:voice:1#dm.call.end"
  @voice_dm_call_signal_event_type "urn:arblarg:ext:voice:1#dm.call.signal"

  @core_event_types [
    "message.create",
    "message.update",
    "message.delete",
    "reaction.add",
    "reaction.remove",
    "read.cursor",
    "membership.upsert",
    "invite.upsert",
    "ban.upsert"
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
    @presence_update_event_type,
    @typing_start_event_type,
    @typing_stop_event_type
  ]

  @moderation_event_types [
    @moderation_action_recorded_event_type
  ]

  @dm_event_types [
    @dm_message_create_event_type
  ]

  @voice_event_types [
    @voice_dm_call_invite_event_type,
    @voice_dm_call_accept_event_type,
    @voice_dm_call_reject_event_type,
    @voice_dm_call_end_event_type,
    @voice_dm_call_signal_event_type
  ]

  @durable_extension_event_types @roles_event_types ++
                                   @permissions_event_types ++
                                   @threads_event_types ++
                                   @moderation_event_types ++
                                   @dm_event_types ++
                                   Enum.take(@voice_event_types, 4)

  @extension_event_types @durable_extension_event_types ++
                           @presence_event_types ++
                           [@voice_dm_call_signal_event_type]

  @durable_event_types [@bootstrap_server_upsert_event_type] ++
                         @core_event_types ++ @durable_extension_event_types

  @supported_event_types @durable_event_types ++ @presence_event_types

  @channel_scoped_durable_event_types @core_event_types ++
                                        @roles_event_types ++
                                        @permissions_event_types ++
                                        @threads_event_types ++ @moderation_event_types

  @extension_event_aliases %{
    "server.upsert" => @bootstrap_server_upsert_event_type,
    "role.upsert" => @roles_role_upsert_event_type,
    "role.assignment.upsert" => @roles_role_assignment_upsert_event_type,
    "permission.overwrite.upsert" => @permissions_overwrite_upsert_event_type,
    "thread.upsert" => @threads_thread_upsert_event_type,
    "thread.archive" => @threads_thread_archive_event_type,
    "presence.update" => @presence_update_event_type,
    "typing.start" => @typing_start_event_type,
    "typing.stop" => @typing_stop_event_type,
    "moderation.action.recorded" => @moderation_action_recorded_event_type,
    "dm.message.create" => @dm_message_create_event_type,
    "dm.call.invite" => @voice_dm_call_invite_event_type,
    "dm.call.accept" => @voice_dm_call_accept_event_type,
    "dm.call.reject" => @voice_dm_call_reject_event_type,
    "dm.call.end" => @voice_dm_call_end_event_type,
    "dm.call.signal" => @voice_dm_call_signal_event_type
  }

  @schema_name_aliases %{
    @bootstrap_server_upsert_event_type => "server.upsert",
    @roles_role_upsert_event_type => "role.upsert",
    @roles_role_assignment_upsert_event_type => "role.assignment.upsert",
    @permissions_overwrite_upsert_event_type => "permission.overwrite.upsert",
    @threads_thread_upsert_event_type => "thread.upsert",
    @threads_thread_archive_event_type => "thread.archive",
    @presence_update_event_type => "presence.update",
    @typing_start_event_type => "typing.start",
    @typing_stop_event_type => "typing.stop",
    @moderation_action_recorded_event_type => "moderation.action.recorded",
    @dm_message_create_event_type => "dm.message.create",
    @voice_dm_call_invite_event_type => "dm.call.invite",
    @voice_dm_call_accept_event_type => "dm.call.accept",
    @voice_dm_call_reject_event_type => "dm.call.reject",
    @voice_dm_call_end_event_type => "dm.call.end",
    @voice_dm_call_signal_event_type => "dm.call.signal"
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
    "read.cursor" => "read.cursor",
    "membership.upsert" => "membership.upsert",
    "invite.upsert" => "invite.upsert",
    "ban.upsert" => "ban.upsert",
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
    @typing_start_event_type => "typing.start",
    "typing.start" => "typing.start",
    @typing_stop_event_type => "typing.stop",
    "typing.stop" => "typing.stop",
    @moderation_action_recorded_event_type => "moderation.action.recorded",
    "moderation.action.recorded" => "moderation.action.recorded",
    @dm_message_create_event_type => "dm.message.create",
    "dm.message.create" => "dm.message.create",
    @voice_dm_call_invite_event_type => "dm.call.invite",
    "dm.call.invite" => "dm.call.invite",
    @voice_dm_call_accept_event_type => "dm.call.accept",
    "dm.call.accept" => "dm.call.accept",
    @voice_dm_call_reject_event_type => "dm.call.reject",
    "dm.call.reject" => "dm.call.reject",
    @voice_dm_call_end_event_type => "dm.call.end",
    "dm.call.end" => "dm.call.end",
    @voice_dm_call_signal_event_type => "dm.call.signal",
    "dm.call.signal" => "dm.call.signal"
  }

  @presence_statuses ["online", "idle", "dnd", "offline", "invisible"]
  @moderation_action_kinds ["warn", "timeout", "kick", "ban", "unban", "delete_message"]
  @call_types ["audio", "video"]
  @call_signal_kinds ["offer", "answer", "ice"]
  @call_end_reasons ["ended", "failed", "disconnected", "timeout", "cancelled"]
  @actor_schema %{
    "type" => "object",
    "required" => ["uri", "username", "domain", "handle"],
    "properties" => %{
      "id" => %{
        "type" => "string",
        "minLength" => 1,
        "format" => "uri",
        "pattern" => "^https?://"
      },
      "uri" => %{
        "type" => "string",
        "minLength" => 1,
        "format" => "uri",
        "pattern" => "^https?://"
      },
      "username" => %{"type" => "string", "minLength" => 1},
      "display_name" => %{"type" => "string"},
      "domain" => %{"type" => "string", "minLength" => 1},
      "handle" => %{"type" => "string", "minLength" => 3},
      "avatar_url" => %{"type" => "string"},
      "key_id" => %{"type" => "string"}
    }
  }
  @attachment_schema %{
    "type" => "object",
    "required" => ["id", "url", "mime_type", "authorization", "retention"],
    "properties" => %{
      "id" => %{"type" => "string", "minLength" => 1},
      "url" => %{"type" => "string", "minLength" => 1, "format" => "uri"},
      "mime_type" => %{"type" => "string", "minLength" => 1},
      "byte_size" => %{"type" => "integer", "minimum" => 0},
      "sha256" => %{"type" => "string", "minLength" => 8},
      "authorization" => %{
        "type" => "string",
        "enum" => ["public", "signed", "origin-authenticated"]
      },
      "retention" => %{
        "type" => "string",
        "enum" => ["origin", "rehosted", "expiring"]
      },
      "expires_at" => %{"type" => "string", "format" => "date-time"},
      "alt_text" => %{"type" => "string"},
      "width" => %{"type" => "integer", "minimum" => 0},
      "height" => %{"type" => "integer", "minimum" => 0},
      "duration_ms" => %{"type" => "integer", "minimum" => 0}
    }
  }

  @schemas %{
    "1.0" => %{
      "envelope" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/envelope",
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
          "event_type" => %{"type" => "string", "enum" => @durable_event_types},
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
        "$id" => "arblarg://schemas/1.0/server.upsert",
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
        "$id" => "arblarg://schemas/1.0/message.create",
        "title" => "Arblarg message.create payload",
        "type" => "object",
        "required" => ["message"],
        "anyOf" => [
          %{"required" => ["server", "channel"]},
          %{"required" => ["refs"]}
        ],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "refs" => %{
            "type" => "object",
            "required" => ["server_id", "channel_id"],
            "properties" => %{
              "server_id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1}
            }
          },
          "message" => %{
            "type" => "object",
            "required" => ["id", "content", "sender"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "content" => %{"type" => "string"},
              "message_type" => %{"type" => "string"},
              "attachments" => %{"type" => "array", "items" => @attachment_schema},
              "created_at" => %{"type" => "string", "format" => "date-time"},
              "edited_at" => %{"type" => "string", "format" => "date-time"},
              "sender" => @actor_schema
            }
          }
        }
      },
      "message.update" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/message.update",
        "title" => "Arblarg message.update payload",
        "type" => "object",
        "required" => ["message"],
        "anyOf" => [
          %{"required" => ["server", "channel"]},
          %{"required" => ["refs"]}
        ],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "refs" => %{
            "type" => "object",
            "required" => ["server_id", "channel_id"],
            "properties" => %{
              "server_id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1}
            }
          },
          "message" => %{
            "type" => "object",
            "required" => ["id", "content", "sender"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "content" => %{"type" => "string"},
              "message_type" => %{"type" => "string"},
              "attachments" => %{"type" => "array", "items" => @attachment_schema},
              "created_at" => %{"type" => "string", "format" => "date-time"},
              "edited_at" => %{"type" => "string", "format" => "date-time"},
              "sender" => @actor_schema
            }
          }
        }
      },
      "message.delete" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/message.delete",
        "title" => "Arblarg message.delete payload",
        "type" => "object",
        "required" => ["message_id"],
        "anyOf" => [
          %{"required" => ["server", "channel"]},
          %{"required" => ["refs"]}
        ],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "refs" => %{
            "type" => "object",
            "required" => ["server_id", "channel_id"],
            "properties" => %{
              "server_id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1}
            }
          },
          "message_id" => %{"type" => "string", "minLength" => 1},
          "deleted_at" => %{"type" => "string", "format" => "date-time"}
        }
      },
      "reaction.add" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/reaction.add",
        "title" => "Arblarg reaction.add payload",
        "type" => "object",
        "required" => ["message_id", "reaction"],
        "anyOf" => [
          %{"required" => ["server", "channel"]},
          %{"required" => ["refs"]}
        ],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "refs" => %{
            "type" => "object",
            "required" => ["server_id", "channel_id"],
            "properties" => %{
              "server_id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1}
            }
          },
          "message_id" => %{"type" => "string", "minLength" => 1},
          "reaction" => %{
            "type" => "object",
            "required" => ["emoji", "actor"],
            "properties" => %{
              "emoji" => %{"type" => "string", "minLength" => 1},
              "actor" => @actor_schema
            }
          }
        }
      },
      "reaction.remove" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/reaction.remove",
        "title" => "Arblarg reaction.remove payload",
        "type" => "object",
        "required" => ["message_id", "reaction"],
        "anyOf" => [
          %{"required" => ["server", "channel"]},
          %{"required" => ["refs"]}
        ],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "refs" => %{
            "type" => "object",
            "required" => ["server_id", "channel_id"],
            "properties" => %{
              "server_id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1}
            }
          },
          "message_id" => %{"type" => "string", "minLength" => 1},
          "reaction" => %{
            "type" => "object",
            "required" => ["emoji", "actor"],
            "properties" => %{
              "emoji" => %{"type" => "string", "minLength" => 1},
              "actor" => @actor_schema
            }
          }
        }
      },
      "read.cursor" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/read.cursor",
        "title" => "Arblarg read.cursor payload",
        "type" => "object",
        "required" => ["read_through_message_id", "actor", "read_at"],
        "anyOf" => [
          %{"required" => ["server", "channel"]},
          %{"required" => ["refs"]}
        ],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "refs" => %{
            "type" => "object",
            "required" => ["server_id", "channel_id"],
            "properties" => %{
              "server_id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1}
            }
          },
          "read_through_message_id" => %{"type" => "string", "minLength" => 1},
          "read_through_sequence" => %{"type" => "integer", "minimum" => 1},
          "actor" => @actor_schema,
          "read_at" => %{"type" => "string", "format" => "date-time"}
        }
      },
      "membership.upsert" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/membership.upsert",
        "title" => "Arblarg membership.upsert payload",
        "type" => "object",
        "required" => ["membership"],
        "anyOf" => [
          %{"required" => ["server", "channel"]},
          %{"required" => ["refs"]}
        ],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "refs" => %{
            "type" => "object",
            "required" => ["server_id", "channel_id"],
            "properties" => %{
              "server_id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1}
            }
          },
          "membership" => %{
            "type" => "object",
            "required" => ["actor", "role", "state", "updated_at"],
            "properties" => %{
              "actor" => @actor_schema,
              "role" => %{
                "type" => "string",
                "enum" => ["owner", "admin", "moderator", "member", "readonly"]
              },
              "state" => %{
                "type" => "string",
                "enum" => ["active", "invited", "left", "banned"]
              },
              "joined_at" => %{"type" => "string", "format" => "date-time"},
              "updated_at" => %{"type" => "string", "format" => "date-time"},
              "metadata" => %{"type" => "object"}
            }
          }
        }
      },
      "invite.upsert" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/invite.upsert",
        "title" => "Arblarg invite.upsert payload",
        "type" => "object",
        "required" => ["invite"],
        "anyOf" => [
          %{"required" => ["server", "channel"]},
          %{"required" => ["refs"]}
        ],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "refs" => %{
            "type" => "object",
            "required" => ["server_id", "channel_id"],
            "properties" => %{
              "server_id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1}
            }
          },
          "invite" => %{
            "type" => "object",
            "required" => ["actor", "target", "role", "state", "invited_at", "updated_at"],
            "properties" => %{
              "actor" => @actor_schema,
              "target" => @actor_schema,
              "role" => %{
                "type" => "string",
                "enum" => ["owner", "admin", "moderator", "member", "readonly"]
              },
              "state" => %{
                "type" => "string",
                "enum" => ["pending", "accepted", "declined", "revoked"]
              },
              "invited_at" => %{"type" => "string", "format" => "date-time"},
              "updated_at" => %{"type" => "string", "format" => "date-time"},
              "metadata" => %{"type" => "object"}
            }
          }
        }
      },
      "ban.upsert" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/ban.upsert",
        "title" => "Arblarg ban.upsert payload",
        "type" => "object",
        "required" => ["ban"],
        "anyOf" => [
          %{"required" => ["server", "channel"]},
          %{"required" => ["refs"]}
        ],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "refs" => %{
            "type" => "object",
            "required" => ["server_id", "channel_id"],
            "properties" => %{
              "server_id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1}
            }
          },
          "ban" => %{
            "type" => "object",
            "required" => ["actor", "target", "state", "banned_at", "updated_at"],
            "properties" => %{
              "actor" => @actor_schema,
              "target" => @actor_schema,
              "state" => %{"type" => "string", "enum" => ["active", "lifted"]},
              "reason" => %{"type" => "string"},
              "banned_at" => %{"type" => "string", "format" => "date-time"},
              "updated_at" => %{"type" => "string", "format" => "date-time"},
              "expires_at" => %{"type" => "string", "format" => "date-time"},
              "metadata" => %{"type" => "object"}
            }
          }
        }
      },
      "role.upsert" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/role.upsert",
        "title" => "Arblarg role.upsert payload",
        "type" => "object",
        "required" => ["server", "channel", "role", "actor"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "actor" => @actor_schema,
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
        "$id" => "arblarg://schemas/1.0/role.assignment.upsert",
        "title" => "Arblarg role.assignment.upsert payload",
        "type" => "object",
        "required" => ["server", "channel", "assignment", "actor"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "actor" => @actor_schema,
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
        "$id" => "arblarg://schemas/1.0/permission.overwrite.upsert",
        "title" => "Arblarg permission.overwrite.upsert payload",
        "type" => "object",
        "required" => ["server", "channel", "overwrite", "actor"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "actor" => @actor_schema,
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
        "$id" => "arblarg://schemas/1.0/thread.upsert",
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
              "owner" => @actor_schema,
              "message_count" => %{"type" => "integer", "minimum" => 0},
              "member_count" => %{"type" => "integer", "minimum" => 0}
            }
          }
        }
      },
      "thread.archive" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/thread.archive",
        "title" => "Arblarg thread.archive payload",
        "type" => "object",
        "required" => ["server", "channel", "thread_id", "archived_at", "actor"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "thread_id" => %{"type" => "string", "minLength" => 1},
          "archived_at" => %{"type" => "string", "format" => "date-time"},
          "reason" => %{"type" => "string"},
          "actor" => @actor_schema
        }
      },
      "presence.update" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/presence.update",
        "title" => "Arblarg presence.update payload",
        "type" => "object",
        "required" => ["presence"],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "refs" => %{
            "type" => "object",
            "properties" => %{
              "server_id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1}
            }
          },
          "presence" => %{
            "type" => "object",
            "required" => ["actor", "status", "updated_at"],
            "properties" => %{
              "actor" => @actor_schema,
              "status" => %{"type" => "string", "enum" => @presence_statuses},
              "updated_at" => %{"type" => "string", "format" => "date-time"},
              "activities" => %{"type" => "array", "items" => %{"type" => "object"}},
              "ttl_ms" => %{"type" => "integer", "minimum" => 100, "maximum" => 86_400_000}
            }
          }
        }
      },
      "typing.start" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/typing.start",
        "title" => "Arblarg typing.start payload",
        "type" => "object",
        "required" => ["actor", "started_at"],
        "anyOf" => [
          %{"required" => ["server", "channel"]},
          %{"required" => ["refs"]}
        ],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "refs" => %{
            "type" => "object",
            "required" => ["server_id", "channel_id"],
            "properties" => %{
              "server_id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1}
            }
          },
          "actor" => @actor_schema,
          "started_at" => %{"type" => "string", "format" => "date-time"},
          "ttl_ms" => %{"type" => "integer", "minimum" => 100, "maximum" => 10_000}
        }
      },
      "typing.stop" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/typing.stop",
        "title" => "Arblarg typing.stop payload",
        "type" => "object",
        "required" => ["actor", "stopped_at"],
        "anyOf" => [
          %{"required" => ["server", "channel"]},
          %{"required" => ["refs"]}
        ],
        "properties" => %{
          "server" => %{"type" => "object"},
          "channel" => %{"type" => "object"},
          "refs" => %{
            "type" => "object",
            "required" => ["server_id", "channel_id"],
            "properties" => %{
              "server_id" => %{"type" => "string", "minLength" => 1},
              "channel_id" => %{"type" => "string", "minLength" => 1}
            }
          },
          "actor" => @actor_schema,
          "stopped_at" => %{"type" => "string", "format" => "date-time"}
        }
      },
      "moderation.action.recorded" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/moderation.action.recorded",
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
              "actor" => @actor_schema,
              "occurred_at" => %{"type" => "string", "format" => "date-time"},
              "duration_seconds" => %{"type" => "integer", "minimum" => 0},
              "reason" => %{"type" => "string"}
            }
          }
        }
      },
      "dm.message.create" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/dm.message.create",
        "title" => "Arblarg dm.message.create payload",
        "type" => "object",
        "required" => ["dm", "message"],
        "properties" => %{
          "dm" => %{
            "type" => "object",
            "required" => ["id", "sender", "recipient"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "sender" => @actor_schema,
              "recipient" => @actor_schema
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
              "attachments" => %{"type" => "array", "items" => @attachment_schema},
              "created_at" => %{"type" => "string", "format" => "date-time"},
              "edited_at" => %{"type" => "string", "format" => "date-time"},
              "sender" => @actor_schema
            }
          }
        }
      },
      "dm.call.invite" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/dm.call.invite",
        "title" => "Arblarg dm.call.invite payload",
        "type" => "object",
        "required" => ["dm", "call"],
        "properties" => %{
          "dm" => %{
            "type" => "object",
            "required" => ["id", "sender", "recipient"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "sender" => @actor_schema,
              "recipient" => @actor_schema
            }
          },
          "call" => %{
            "type" => "object",
            "required" => ["id", "dm_id", "call_type", "actor", "initiated_at"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "dm_id" => %{"type" => "string", "minLength" => 1},
              "call_type" => %{"type" => "string", "enum" => @call_types},
              "actor" => @actor_schema,
              "initiated_at" => %{"type" => "string", "format" => "date-time"},
              "metadata" => %{"type" => "object"}
            }
          }
        }
      },
      "dm.call.accept" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/dm.call.accept",
        "title" => "Arblarg dm.call.accept payload",
        "type" => "object",
        "required" => ["dm", "call_id", "actor", "accepted_at"],
        "properties" => %{
          "dm" => %{
            "type" => "object",
            "required" => ["id", "sender", "recipient"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "sender" => @actor_schema,
              "recipient" => @actor_schema
            }
          },
          "call_id" => %{"type" => "string", "minLength" => 1},
          "actor" => @actor_schema,
          "accepted_at" => %{"type" => "string", "format" => "date-time"},
          "metadata" => %{"type" => "object"}
        }
      },
      "dm.call.reject" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/dm.call.reject",
        "title" => "Arblarg dm.call.reject payload",
        "type" => "object",
        "required" => ["dm", "call_id", "actor", "rejected_at"],
        "properties" => %{
          "dm" => %{
            "type" => "object",
            "required" => ["id", "sender", "recipient"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "sender" => @actor_schema,
              "recipient" => @actor_schema
            }
          },
          "call_id" => %{"type" => "string", "minLength" => 1},
          "actor" => @actor_schema,
          "rejected_at" => %{"type" => "string", "format" => "date-time"},
          "reason" => %{"type" => "string"},
          "metadata" => %{"type" => "object"}
        }
      },
      "dm.call.end" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/dm.call.end",
        "title" => "Arblarg dm.call.end payload",
        "type" => "object",
        "required" => ["dm", "call_id", "actor", "ended_at"],
        "properties" => %{
          "dm" => %{
            "type" => "object",
            "required" => ["id", "sender", "recipient"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "sender" => @actor_schema,
              "recipient" => @actor_schema
            }
          },
          "call_id" => %{"type" => "string", "minLength" => 1},
          "actor" => @actor_schema,
          "ended_at" => %{"type" => "string", "format" => "date-time"},
          "reason" => %{"type" => "string", "enum" => @call_end_reasons},
          "metadata" => %{"type" => "object"}
        }
      },
      "dm.call.signal" => %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "$id" => "arblarg://schemas/1.0/dm.call.signal",
        "title" => "Arblarg dm.call.signal payload",
        "type" => "object",
        "required" => ["dm", "call_id", "actor", "signal", "sent_at"],
        "properties" => %{
          "dm" => %{
            "type" => "object",
            "required" => ["id", "sender", "recipient"],
            "properties" => %{
              "id" => %{"type" => "string", "minLength" => 1},
              "sender" => @actor_schema,
              "recipient" => @actor_schema
            }
          },
          "call_id" => %{"type" => "string", "minLength" => 1},
          "actor" => @actor_schema,
          "sent_at" => %{"type" => "string", "format" => "date-time"},
          "signal" => %{
            "type" => "object",
            "required" => ["kind", "payload"],
            "properties" => %{
              "kind" => %{"type" => "string", "enum" => @call_signal_kinds},
              "payload" => %{"type" => "object"},
              "sequence" => %{"type" => "integer", "minimum" => 0}
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
  def voice_extension_urn, do: @voice_extension_urn
  def roles_event_types, do: @roles_event_types
  def permissions_event_types, do: @permissions_event_types
  def threads_event_types, do: @threads_event_types
  def presence_event_types, do: @presence_event_types
  def moderation_event_types, do: @moderation_event_types
  def dm_event_types, do: @dm_event_types
  def voice_event_types, do: @voice_event_types
  def dm_message_create_event_type, do: @dm_message_create_event_type
  def dm_call_invite_event_type, do: @voice_dm_call_invite_event_type
  def dm_call_accept_event_type, do: @voice_dm_call_accept_event_type
  def dm_call_reject_event_type, do: @voice_dm_call_reject_event_type
  def dm_call_end_event_type, do: @voice_dm_call_end_event_type
  def dm_call_signal_event_type, do: @voice_dm_call_signal_event_type
  def schema_bindings, do: @schema_bindings
  def durable_event_types, do: @durable_event_types
  def ephemeral_event_types, do: @presence_event_types ++ [@voice_dm_call_signal_event_type]

  def canonical_event_type(event_type) when is_binary(event_type) do
    Map.get(@extension_event_aliases, event_type, event_type)
  end

  def canonical_event_type(event_type), do: event_type

  def supported_event_types, do: @supported_event_types

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

  def canonical_json_payload(value) do
    canonical_json(value)
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
    case normalize_private_key(private_key_material) do
      {:ok, private_key} ->
        :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
        |> Base.url_encode64(padding: false)

      _ ->
        ""
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

  def verification_public_key(material) do
    normalize_verification_public_key(material)
  end

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
    envelope = normalize_envelope_for_signing(envelope)

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
      verification_materials = key_lookup_fun.(key_id) |> List.wrap()

      Enum.any?(verification_materials, fn public_key_material ->
        verify_payload_signature(
          canonical_event_signature_payload(envelope_without_signature),
          public_key_material,
          value
        )
      end)
    else
      false
    end
  end

  def verify_event_envelope_signature(_, _), do: false

  def canonical_event_payload_for_signing(envelope) when is_map(envelope) do
    envelope
    |> normalize_envelope_for_signing()
    |> Map.delete("signature")
    |> canonical_event_signature_payload()
  end

  def canonical_event_payload_for_signing(_), do: ""

  def validate_event_envelope(envelope) when is_map(envelope) do
    protocol_id = envelope["protocol_id"]
    protocol_name = envelope["protocol"]
    protocol_version = envelope["protocol_version"]
    raw_event_type = envelope["event_type"]
    event_type = canonical_event_type(raw_event_type)
    payload = envelope["payload"]
    idempotency_key = envelope["idempotency_key"]

    cond do
      protocol_id != @protocol_id ->
        {:error, :unsupported_protocol}

      protocol_name != @protocol_name ->
        {:error, :unsupported_protocol}

      protocol_version != @protocol_version ->
        {:error, :unsupported_version}

      raw_event_type not in @durable_event_types ->
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

      !valid_signature_map?(envelope["signature"]) ->
        {:error, :invalid_signature}

      true ->
        with :ok <- validate_event_payload(event_type, payload) do
          validate_stream_binding(event_type, envelope["stream_id"], payload)
        end
    end
  end

  def validate_event_envelope(_), do: {:error, :invalid_payload}

  def validate_event_payload("message.create", payload),
    do: validate_message_upsert_payload(payload)

  def validate_event_payload("message.update", payload),
    do: validate_message_upsert_payload(payload)

  def validate_event_payload(@bootstrap_server_upsert_event_type, payload) do
    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !valid_server_object?(payload["server"], require_name?: true) ->
        {:error, :invalid_event_payload}

      !valid_server_channels?(payload["channels"]) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  def validate_event_payload("server.upsert", payload),
    do: validate_event_payload(@bootstrap_server_upsert_event_type, payload)

  def validate_event_payload("message.delete", payload) do
    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !valid_channel_event_context?(payload) ->
        {:error, :invalid_event_payload}

      is_map(payload["server"]) and !valid_server_object?(payload["server"]) ->
        {:error, :invalid_event_payload}

      is_map(payload["channel"]) and !valid_channel_object?(payload["channel"]) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(payload["message_id"]) ->
        {:error, :invalid_event_payload}

      !valid_optional_iso8601?(payload["deleted_at"]) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  def validate_event_payload("reaction.add", payload), do: validate_reaction_payload(payload)
  def validate_event_payload("reaction.remove", payload), do: validate_reaction_payload(payload)

  def validate_event_payload("read.cursor", payload) do
    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !valid_channel_event_context?(payload) ->
        {:error, :invalid_event_payload}

      is_map(payload["server"]) and !valid_server_object?(payload["server"]) ->
        {:error, :invalid_event_payload}

      is_map(payload["channel"]) and !valid_channel_object?(payload["channel"]) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(payload["read_through_message_id"]) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(payload["actor"]) ->
        {:error, :invalid_event_payload}

      !valid_positive_integer_or_nil?(payload["read_through_sequence"]) ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(payload["read_at"]) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  def validate_event_payload("membership.upsert", payload) do
    membership = if is_map(payload), do: payload["membership"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !valid_channel_event_context?(payload) ->
        {:error, :invalid_event_payload}

      is_map(payload["server"]) and !valid_server_object?(payload["server"]) ->
        {:error, :invalid_event_payload}

      is_map(payload["channel"]) and !valid_channel_object?(payload["channel"]) ->
        {:error, :invalid_event_payload}

      !is_map(membership) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(membership["actor"]) ->
        {:error, :invalid_event_payload}

      membership["role"] not in ["owner", "admin", "moderator", "member", "readonly"] ->
        {:error, :invalid_event_payload}

      membership["state"] not in ["active", "invited", "left", "banned"] ->
        {:error, :invalid_event_payload}

      !valid_optional_iso8601?(membership["joined_at"]) ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(membership["updated_at"]) ->
        {:error, :invalid_event_payload}

      !is_map(membership["metadata"] || %{}) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  def validate_event_payload("invite.upsert", payload) do
    invite = if is_map(payload), do: payload["invite"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !valid_channel_event_context?(payload) ->
        {:error, :invalid_event_payload}

      is_map(payload["server"]) and !valid_server_object?(payload["server"]) ->
        {:error, :invalid_event_payload}

      is_map(payload["channel"]) and !valid_channel_object?(payload["channel"]) ->
        {:error, :invalid_event_payload}

      !is_map(invite) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(invite["actor"]) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(invite["target"]) ->
        {:error, :invalid_event_payload}

      invite["role"] not in ["owner", "admin", "moderator", "member", "readonly"] ->
        {:error, :invalid_event_payload}

      invite["state"] not in ["pending", "accepted", "declined", "revoked"] ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(invite["invited_at"]) ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(invite["updated_at"]) ->
        {:error, :invalid_event_payload}

      !is_map(invite["metadata"] || %{}) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  def validate_event_payload("ban.upsert", payload) do
    ban = if is_map(payload), do: payload["ban"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !valid_channel_event_context?(payload) ->
        {:error, :invalid_event_payload}

      is_map(payload["server"]) and !valid_server_object?(payload["server"]) ->
        {:error, :invalid_event_payload}

      is_map(payload["channel"]) and !valid_channel_object?(payload["channel"]) ->
        {:error, :invalid_event_payload}

      !is_map(ban) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(ban["actor"]) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(ban["target"]) ->
        {:error, :invalid_event_payload}

      ban["state"] not in ["active", "lifted"] ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(ban["banned_at"]) ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(ban["updated_at"]) ->
        {:error, :invalid_event_payload}

      !valid_optional_iso8601?(ban["expires_at"]) ->
        {:error, :invalid_event_payload}

      !is_map(ban["metadata"] || %{}) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
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

  def validate_event_payload(@typing_start_event_type, payload),
    do: validate_typing_payload(payload, :start)

  def validate_event_payload("typing.start", payload),
    do: validate_event_payload(@typing_start_event_type, payload)

  def validate_event_payload(@typing_stop_event_type, payload),
    do: validate_typing_payload(payload, :stop)

  def validate_event_payload("typing.stop", payload),
    do: validate_event_payload(@typing_stop_event_type, payload)

  def validate_event_payload(@moderation_action_recorded_event_type, payload),
    do: validate_moderation_action_recorded_payload(payload)

  def validate_event_payload("moderation.action.recorded", payload),
    do: validate_event_payload(@moderation_action_recorded_event_type, payload)

  def validate_event_payload(@dm_message_create_event_type, payload),
    do: validate_dm_message_create_payload(payload)

  def validate_event_payload("dm.message.create", payload),
    do: validate_event_payload(@dm_message_create_event_type, payload)

  def validate_event_payload(@voice_dm_call_invite_event_type, payload),
    do: validate_dm_call_invite_payload(payload)

  def validate_event_payload("dm.call.invite", payload),
    do: validate_event_payload(@voice_dm_call_invite_event_type, payload)

  def validate_event_payload(@voice_dm_call_accept_event_type, payload),
    do: validate_dm_call_accept_payload(payload)

  def validate_event_payload("dm.call.accept", payload),
    do: validate_event_payload(@voice_dm_call_accept_event_type, payload)

  def validate_event_payload(@voice_dm_call_reject_event_type, payload),
    do: validate_dm_call_reject_payload(payload)

  def validate_event_payload("dm.call.reject", payload),
    do: validate_event_payload(@voice_dm_call_reject_event_type, payload)

  def validate_event_payload(@voice_dm_call_end_event_type, payload),
    do: validate_dm_call_end_payload(payload)

  def validate_event_payload("dm.call.end", payload),
    do: validate_event_payload(@voice_dm_call_end_event_type, payload)

  def validate_event_payload(@voice_dm_call_signal_event_type, payload),
    do: validate_dm_call_signal_payload(payload)

  def validate_event_payload("dm.call.signal", payload),
    do: validate_event_payload(@voice_dm_call_signal_event_type, payload)

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

  defp normalize_private_key(key) when is_binary(key) and byte_size(key) == 32,
    do: {:ok, key}

  defp normalize_private_key(%{private_key: key}), do: normalize_private_key(key)
  defp normalize_private_key(%{secret: secret}), do: normalize_private_key(secret)

  defp normalize_private_key(key) when is_binary(key) do
    trimmed = String.trim(key)

    if not Elektrine.Strings.present?(trimmed) do
      {:error, :invalid_private_key}
    else
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
  defp normalize_public_key(%{"public_key" => key}), do: normalize_public_key(key)

  defp normalize_public_key(key) when is_binary(key) do
    trimmed = String.trim(key)

    if not Elektrine.Strings.present?(trimmed) do
      {:error, :invalid_public_key}
    else
      case decode_32_byte_key(trimmed) do
        {:ok, decoded} ->
          {:ok, decoded}

        :error ->
          {:error, :invalid_public_key}
      end
    end
  end

  defp normalize_public_key(_), do: {:error, :invalid_public_key}

  defp normalize_verification_public_key(%{public_key: key}), do: normalize_public_key(key)
  defp normalize_verification_public_key(%{"public_key" => key}), do: normalize_public_key(key)

  defp normalize_verification_public_key(%{secret: secret}) when is_binary(secret) do
    if Elektrine.Strings.present?(secret) do
      {public_key, _private_key} = derive_keypair_from_secret(secret)
      {:ok, public_key}
    else
      {:error, :invalid_public_key}
    end
  end

  defp normalize_verification_public_key(%{"secret" => secret}) when is_binary(secret) do
    if Elektrine.Strings.present?(secret) do
      {public_key, _private_key} = derive_keypair_from_secret(secret)
      {:ok, public_key}
    else
      {:error, :invalid_public_key}
    end
  end

  defp normalize_verification_public_key(key) when is_binary(key) do
    case normalize_public_key(key) do
      {:ok, public_key} ->
        {:ok, public_key}

      {:error, :invalid_public_key} ->
        trimmed = String.trim(key)

        if not Elektrine.Strings.present?(trimmed) do
          {:error, :invalid_public_key}
        else
          {public_key, _private_key} = derive_keypair_from_secret(trimmed)
          {:ok, public_key}
        end
    end
  end

  defp normalize_verification_public_key(_), do: {:error, :invalid_public_key}

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
      !valid_channel_event_context?(payload) -> {:error, :invalid_event_payload}
      !is_map(message) -> {:error, :invalid_event_payload}
      !non_empty_binary?(message["id"]) -> {:error, :invalid_event_payload}
      !valid_message_content?(message) -> {:error, :invalid_event_payload}
      !valid_message_metadata?(message) -> {:error, :invalid_event_payload}
      !valid_actor_payload?(message["sender"]) -> {:error, :invalid_event_payload}
      !valid_message_channel_match?(payload, message) -> {:error, :invalid_event_payload}
      true -> :ok
    end
  end

  defp validate_reaction_payload(payload) do
    reaction = if is_map(payload), do: payload["reaction"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !valid_channel_event_context?(payload) ->
        {:error, :invalid_event_payload}

      is_map(payload["server"]) and !valid_server_object?(payload["server"]) ->
        {:error, :invalid_event_payload}

      is_map(payload["channel"]) and !valid_channel_object?(payload["channel"]) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(payload["message_id"]) ->
        {:error, :invalid_event_payload}

      !is_map(reaction) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(reaction["emoji"]) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(reaction["actor"]) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp validate_role_upsert_payload(payload) do
    role = if is_map(payload), do: payload["role"], else: nil

    cond do
      !is_map(payload) -> {:error, :invalid_event_payload}
      !valid_server_object?(payload["server"]) -> {:error, :invalid_event_payload}
      !valid_channel_object?(payload["channel"]) -> {:error, :invalid_event_payload}
      !valid_channel_event_context?(payload) -> {:error, :invalid_event_payload}
      !valid_actor_payload?(payload["actor"]) -> {:error, :invalid_event_payload}
      !is_map(role) -> {:error, :invalid_event_payload}
      !non_empty_binary?(role["id"]) -> {:error, :invalid_event_payload}
      !non_empty_binary?(role["name"]) -> {:error, :invalid_event_payload}
      !is_integer(role["position"]) or role["position"] < 0 -> {:error, :invalid_event_payload}
      !valid_string_list?(role["permissions"]) -> {:error, :invalid_event_payload}
      !valid_optional_binary?(role["color"]) -> {:error, :invalid_event_payload}
      !valid_boolean_or_nil?(role["hoist"]) -> {:error, :invalid_event_payload}
      !valid_boolean_or_nil?(role["mentionable"]) -> {:error, :invalid_event_payload}
      true -> :ok
    end
  end

  defp validate_role_assignment_upsert_payload(payload) do
    assignment = if is_map(payload), do: payload["assignment"], else: nil

    cond do
      !is_map(payload) -> {:error, :invalid_event_payload}
      !valid_server_object?(payload["server"]) -> {:error, :invalid_event_payload}
      !valid_channel_object?(payload["channel"]) -> {:error, :invalid_event_payload}
      !valid_channel_event_context?(payload) -> {:error, :invalid_event_payload}
      !valid_actor_payload?(payload["actor"]) -> {:error, :invalid_event_payload}
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
      !valid_server_object?(payload["server"]) -> {:error, :invalid_event_payload}
      !valid_channel_object?(payload["channel"]) -> {:error, :invalid_event_payload}
      !valid_channel_event_context?(payload) -> {:error, :invalid_event_payload}
      !valid_actor_payload?(payload["actor"]) -> {:error, :invalid_event_payload}
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

      !valid_server_object?(payload["server"]) ->
        {:error, :invalid_event_payload}

      !valid_channel_object?(payload["channel"]) ->
        {:error, :invalid_event_payload}

      !valid_channel_event_context?(payload) ->
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

      !valid_actor_payload?(thread["owner"]) ->
        {:error, :invalid_event_payload}

      !valid_non_negative_integer_or_nil?(thread["message_count"]) ->
        {:error, :invalid_event_payload}

      !valid_non_negative_integer_or_nil?(thread["member_count"]) ->
        {:error, :invalid_event_payload}

      !valid_thread_channel_match?(payload, thread) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp validate_typing_payload(payload, mode) do
    timestamp_field = if mode == :start, do: "started_at", else: "stopped_at"
    ttl_ms = if is_map(payload), do: payload["ttl_ms"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !valid_channel_event_context?(payload) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(payload["actor"]) ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(payload[timestamp_field]) ->
        {:error, :invalid_event_payload}

      !is_nil(ttl_ms) and (!is_integer(ttl_ms) or ttl_ms < 100 or ttl_ms > 10_000) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp validate_thread_archive_payload(payload) do
    cond do
      !is_map(payload) -> {:error, :invalid_event_payload}
      !valid_server_object?(payload["server"]) -> {:error, :invalid_event_payload}
      !valid_channel_object?(payload["channel"]) -> {:error, :invalid_event_payload}
      !valid_channel_event_context?(payload) -> {:error, :invalid_event_payload}
      !non_empty_binary?(payload["thread_id"]) -> {:error, :invalid_event_payload}
      !valid_iso8601?(payload["archived_at"]) -> {:error, :invalid_event_payload}
      !valid_optional_binary?(payload["reason"]) -> {:error, :invalid_event_payload}
      !valid_actor_payload?(payload["actor"]) -> {:error, :invalid_event_payload}
      true -> :ok
    end
  end

  defp validate_presence_update_payload(payload) do
    presence = if is_map(payload), do: payload["presence"], else: nil
    activities = if is_map(presence), do: presence["activities"], else: nil
    ttl_ms = if is_map(presence), do: presence["ttl_ms"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !valid_optional_presence_context?(payload) ->
        {:error, :invalid_event_payload}

      !is_map(presence) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(presence["actor"]) ->
        {:error, :invalid_event_payload}

      presence["status"] not in @presence_statuses ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(presence["updated_at"]) ->
        {:error, :invalid_event_payload}

      !is_nil(activities) and (!is_list(activities) or Enum.any?(activities, &(not is_map(&1)))) ->
        {:error, :invalid_event_payload}

      !is_nil(ttl_ms) and (!is_integer(ttl_ms) or ttl_ms < 100 or ttl_ms > 86_400_000) ->
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

      !valid_server_object?(payload["server"]) ->
        {:error, :invalid_event_payload}

      !valid_channel_object?(payload["channel"]) ->
        {:error, :invalid_event_payload}

      !valid_channel_event_context?(payload) ->
        {:error, :invalid_event_payload}

      !is_map(action) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(action["id"]) ->
        {:error, :invalid_event_payload}

      action["kind"] not in @moderation_action_kinds ->
        {:error, :invalid_event_payload}

      !valid_opaque_target?(action["target"]) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(action["actor"]) ->
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

      !non_empty_binary?(dm["id"]) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(dm["sender"]) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(dm["recipient"]) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(message["id"]) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(message["dm_id"]) ->
        {:error, :invalid_event_payload}

      message["dm_id"] != dm["id"] ->
        {:error, :invalid_event_payload}

      !valid_message_content?(message) ->
        {:error, :invalid_event_payload}

      !valid_message_metadata?(message) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(message["sender"]) ->
        {:error, :invalid_event_payload}

      !same_actor_identity?(dm["sender"], message["sender"]) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp validate_dm_call_invite_payload(payload) do
    dm = if is_map(payload), do: payload["dm"], else: nil
    call = if is_map(payload), do: payload["call"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !valid_dm_event_context?(dm) ->
        {:error, :invalid_event_payload}

      !is_map(call) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(call["id"]) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(call["dm_id"]) ->
        {:error, :invalid_event_payload}

      call["dm_id"] != dm["id"] ->
        {:error, :invalid_event_payload}

      call["call_type"] not in @call_types ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(call["actor"]) ->
        {:error, :invalid_event_payload}

      !same_actor_identity?(dm["sender"], call["actor"]) ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(call["initiated_at"]) ->
        {:error, :invalid_event_payload}

      !is_map(call["metadata"] || %{}) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp validate_dm_call_accept_payload(payload),
    do: validate_dm_call_state_payload(payload, "accepted_at", nil)

  defp validate_dm_call_reject_payload(payload),
    do: validate_dm_call_state_payload(payload, "rejected_at", :reject)

  defp validate_dm_call_end_payload(payload),
    do: validate_dm_call_state_payload(payload, "ended_at", :end_call)

  defp validate_dm_call_state_payload(payload, timestamp_field, mode) do
    dm = if is_map(payload), do: payload["dm"], else: nil
    actor = if is_map(payload), do: payload["actor"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !valid_dm_event_context?(dm) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(payload["call_id"]) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(actor) ->
        {:error, :invalid_event_payload}

      !same_actor_identity?(dm["recipient"], actor) and !same_actor_identity?(dm["sender"], actor) ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(payload[timestamp_field]) ->
        {:error, :invalid_event_payload}

      mode == :reject and !valid_optional_binary?(payload["reason"]) ->
        {:error, :invalid_event_payload}

      mode == :end_call and payload["reason"] not in [nil | @call_end_reasons] ->
        {:error, :invalid_event_payload}

      !is_map(payload["metadata"] || %{}) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp validate_dm_call_signal_payload(payload) do
    dm = if is_map(payload), do: payload["dm"], else: nil
    actor = if is_map(payload), do: payload["actor"], else: nil
    signal = if is_map(payload), do: payload["signal"], else: nil
    signal_payload = if is_map(signal), do: signal["payload"], else: nil

    cond do
      !is_map(payload) ->
        {:error, :invalid_event_payload}

      !valid_dm_event_context?(dm) ->
        {:error, :invalid_event_payload}

      !non_empty_binary?(payload["call_id"]) ->
        {:error, :invalid_event_payload}

      !valid_actor_payload?(actor) ->
        {:error, :invalid_event_payload}

      !same_actor_identity?(dm["recipient"], actor) and !same_actor_identity?(dm["sender"], actor) ->
        {:error, :invalid_event_payload}

      !valid_iso8601?(payload["sent_at"]) ->
        {:error, :invalid_event_payload}

      !is_map(signal) ->
        {:error, :invalid_event_payload}

      signal["kind"] not in @call_signal_kinds ->
        {:error, :invalid_event_payload}

      !is_map(signal_payload) ->
        {:error, :invalid_event_payload}

      !valid_dm_call_signal_payload?(signal["kind"], signal_payload) ->
        {:error, :invalid_event_payload}

      !is_nil(signal["sequence"]) and
          (!is_integer(signal["sequence"]) or signal["sequence"] < 0) ->
        {:error, :invalid_event_payload}

      true ->
        :ok
    end
  end

  defp valid_dm_event_context?(dm) when is_map(dm) do
    non_empty_binary?(dm["id"]) and valid_actor_payload?(dm["sender"]) and
      valid_actor_payload?(dm["recipient"])
  end

  defp valid_dm_event_context?(_dm), do: false

  defp valid_dm_call_signal_payload?("offer", payload) when is_map(payload) do
    valid_sdp_signal_payload?(payload, "offer")
  end

  defp valid_dm_call_signal_payload?("answer", payload) when is_map(payload) do
    valid_sdp_signal_payload?(payload, "answer")
  end

  defp valid_dm_call_signal_payload?("ice", payload) when is_map(payload) do
    candidate = payload["candidate"]

    is_map(candidate) and non_empty_binary?(candidate["candidate"]) and
      byte_size(candidate["candidate"]) <= 4096 and
      (is_nil(candidate["sdpMid"]) or
         (is_binary(candidate["sdpMid"]) and byte_size(candidate["sdpMid"]) <= 128)) and
      (is_nil(candidate["sdpMLineIndex"]) or
         (is_integer(candidate["sdpMLineIndex"]) and candidate["sdpMLineIndex"] >= 0 and
            candidate["sdpMLineIndex"] <= 1024)) and
      (is_nil(candidate["usernameFragment"]) or
         (is_binary(candidate["usernameFragment"]) and
            byte_size(candidate["usernameFragment"]) <= 256))
  end

  defp valid_dm_call_signal_payload?(_kind, _payload), do: false

  defp valid_sdp_signal_payload?(payload, expected_type) when is_map(payload) do
    sdp = payload["sdp"]

    is_map(sdp) and sdp["type"] == expected_type and is_binary(sdp["sdp"]) and
      byte_size(sdp["sdp"]) > 0 and byte_size(sdp["sdp"]) <= 100_000 and
      String.starts_with?(sdp["sdp"], "v=0")
  end

  defp valid_sdp_signal_payload?(_payload, _expected_type), do: false

  defp validate_stream_binding(@bootstrap_server_upsert_event_type, stream_id, payload)
       when is_map(payload) do
    validate_exact_stream_binding(stream_id, "server", get_in(payload, ["server", "id"]))
  end

  defp validate_stream_binding(event_type, stream_id, payload)
       when event_type in @channel_scoped_durable_event_types and is_map(payload) do
    case context_identifier(payload, "channel") do
      {:ok, channel_id} ->
        validate_exact_stream_binding(stream_id, "channel", channel_id)

      :error ->
        {:error, :invalid_event_payload}
    end
  end

  defp validate_stream_binding(@dm_message_create_event_type, "dm:" <> dm_id, payload)
       when is_map(payload) do
    if get_in(payload, ["dm", "id"]) == dm_id do
      :ok
    else
      {:error, :invalid_event_payload}
    end
  end

  defp validate_stream_binding(@dm_message_create_event_type, _stream_id, _payload),
    do: {:error, :invalid_event_payload}

  defp validate_stream_binding(event_type, "dm:" <> dm_id, payload)
       when event_type in [
              @voice_dm_call_invite_event_type,
              @voice_dm_call_accept_event_type,
              @voice_dm_call_reject_event_type,
              @voice_dm_call_end_event_type
            ] and is_map(payload) do
    if get_in(payload, ["dm", "id"]) == dm_id do
      :ok
    else
      {:error, :invalid_event_payload}
    end
  end

  defp validate_stream_binding(event_type, _stream_id, _payload)
       when event_type in [
              @voice_dm_call_invite_event_type,
              @voice_dm_call_accept_event_type,
              @voice_dm_call_reject_event_type,
              @voice_dm_call_end_event_type
            ],
       do: {:error, :invalid_event_payload}

  defp validate_stream_binding(_event_type, _stream_id, _payload), do: :ok

  defp validate_exact_stream_binding(stream_id, scope, identifier)
       when is_binary(stream_id) and is_binary(scope) and is_binary(identifier) do
    if stream_id == "#{scope}:#{identifier}" do
      :ok
    else
      {:error, :invalid_event_payload}
    end
  end

  defp validate_exact_stream_binding(_stream_id, _scope, _identifier),
    do: {:error, :invalid_event_payload}

  defp valid_channel_event_context?(payload) when is_map(payload) do
    valid_server_context?(payload) and valid_channel_context?(payload)
  end

  defp valid_channel_event_context?(_), do: false

  defp valid_server_context?(payload) when is_map(payload) do
    case context_identifier(payload, "server") do
      {:ok, server_id} -> valid_absolute_http_uri?(server_id)
      :error -> false
    end
  end

  defp valid_server_context?(_payload), do: false

  defp valid_optional_presence_context?(payload) when is_map(payload) do
    refs = normalized_refs(payload)

    cond do
      is_map(payload["channel"]) or is_binary(refs["channel_id"]) ->
        valid_channel_event_context?(payload)

      is_map(payload["server"]) or is_binary(refs["server_id"]) ->
        valid_server_context?(payload)

      true ->
        true
    end
  end

  defp valid_optional_presence_context?(_payload), do: false

  defp valid_channel_context?(payload) when is_map(payload) do
    case context_identifier(payload, "channel") do
      {:ok, channel_id} -> valid_absolute_http_uri?(channel_id)
      :error -> false
    end
  end

  defp valid_channel_context?(_payload), do: false

  defp context_identifier(payload, field)
       when is_map(payload) and field in ["server", "channel"] do
    refs = normalized_refs(payload)
    object_id = get_in(payload, [field, "id"])
    ref_id = refs["#{field}_id"]

    cond do
      is_binary(object_id) and is_binary(ref_id) and object_id != ref_id ->
        :error

      is_binary(object_id) ->
        {:ok, object_id}

      is_binary(ref_id) ->
        {:ok, ref_id}

      true ->
        :error
    end
  end

  defp context_identifier(_payload, _field), do: :error

  defp normalized_refs(%{"refs" => refs}) when is_map(refs), do: refs
  defp normalized_refs(%{refs: refs}) when is_map(refs), do: refs
  defp normalized_refs(_payload), do: %{}

  defp valid_server_object?(server, opts \\ [])

  defp valid_server_object?(server, opts) when is_map(server) do
    require_name? = Keyword.get(opts, :require_name?, false)
    require_id? = Keyword.get(opts, :require_id?, true)

    cond do
      require_id? and !valid_absolute_http_uri?(server["id"]) ->
        false

      !valid_optional_binary?(server["name"], allow_empty?: false, required?: require_name?) ->
        false

      !valid_optional_binary?(server["description"]) ->
        false

      !valid_optional_binary?(server["icon_url"]) ->
        false

      !valid_boolean_or_nil?(server["is_public"]) ->
        false

      !valid_non_negative_integer_or_nil?(server["member_count"]) ->
        false

      true ->
        true
    end
  end

  defp valid_server_object?(_server, _opts), do: false

  defp valid_channel_object?(channel, opts \\ [])

  defp valid_channel_object?(channel, opts) when is_map(channel) do
    require_name? = Keyword.get(opts, :require_name?, false)
    require_id? = Keyword.get(opts, :require_id?, true)

    cond do
      require_id? and !valid_absolute_http_uri?(channel["id"]) ->
        false

      !valid_optional_binary?(channel["name"], allow_empty?: false, required?: require_name?) ->
        false

      !valid_optional_binary?(channel["description"]) ->
        false

      !valid_optional_binary?(channel["topic"]) ->
        false

      !valid_non_negative_integer_or_nil?(channel["position"]) ->
        false

      !valid_boolean_or_nil?(channel["is_public"]) ->
        false

      !valid_boolean_or_nil?(channel["approval_mode_enabled"]) ->
        false

      true ->
        true
    end
  end

  defp valid_channel_object?(_channel, _opts), do: false

  defp valid_server_channels?(channels) when is_list(channels) do
    Enum.all?(channels, &valid_channel_object?(&1, require_name?: true))
  end

  defp valid_server_channels?(_channels), do: false

  defp valid_message_content?(message) when is_map(message) do
    Map.has_key?(message, "content") and is_binary(message["content"])
  end

  defp valid_message_content?(_message), do: false

  defp valid_message_metadata?(message) when is_map(message) do
    valid_optional_binary?(message["message_type"]) and
      valid_attachment_list?(message["attachments"]) and
      valid_optional_iso8601?(message["created_at"]) and
      valid_optional_iso8601?(message["edited_at"])
  end

  defp valid_message_metadata?(_message), do: false

  defp valid_message_channel_match?(payload, message) when is_map(payload) and is_map(message) do
    case message["channel_id"] do
      nil ->
        true

      channel_id when is_binary(channel_id) ->
        match?({:ok, ^channel_id}, context_identifier(payload, "channel"))

      _ ->
        false
    end
  end

  defp valid_message_channel_match?(_payload, _message), do: false

  defp valid_thread_channel_match?(payload, thread) when is_map(payload) and is_map(thread) do
    case thread["channel_id"] do
      channel_id when is_binary(channel_id) ->
        match?({:ok, ^channel_id}, context_identifier(payload, "channel"))

      _ ->
        false
    end
  end

  defp valid_thread_channel_match?(_payload, _thread), do: false

  defp same_actor_identity?(left, right) when is_map(left) and is_map(right) do
    valid_actor_payload?(left) and valid_actor_payload?(right) and
      normalize_actor_identity_field(left, "uri") == normalize_actor_identity_field(right, "uri")
  end

  defp same_actor_identity?(_left, _right), do: false

  defp valid_opaque_target?(target) when is_map(target) do
    non_empty_binary?(target["type"]) and non_empty_binary?(target["id"])
  end

  defp valid_opaque_target?(_target), do: false

  defp valid_target?(target, allowed_types) when is_map(target) and is_list(allowed_types) do
    non_empty_binary?(target["id"]) and target["type"] in allowed_types
  end

  defp valid_target?(_target, _allowed_types), do: false

  defp valid_string_list?(values) when is_list(values) do
    Enum.all?(values, &non_empty_binary?/1)
  end

  defp valid_string_list?(_values), do: false

  defp valid_attachment_list?(nil), do: true

  defp valid_attachment_list?(attachments) when is_list(attachments) do
    Enum.all?(attachments, &valid_attachment?/1)
  end

  defp valid_attachment_list?(_attachments), do: false

  defp valid_attachment?(attachment) when is_map(attachment) do
    authorization = attachment["authorization"]
    retention = attachment["retention"]

    non_empty_binary?(attachment["id"]) and
      non_empty_binary?(attachment["url"]) and
      non_empty_binary?(attachment["mime_type"]) and
      authorization in ["public", "signed", "origin-authenticated"] and
      retention in ["origin", "rehosted", "expiring"] and
      valid_non_negative_integer_or_nil?(attachment["byte_size"]) and
      valid_non_negative_integer_or_nil?(attachment["width"]) and
      valid_non_negative_integer_or_nil?(attachment["height"]) and
      valid_non_negative_integer_or_nil?(attachment["duration_ms"]) and
      valid_optional_iso8601?(attachment["expires_at"])
  end

  defp valid_attachment?(_attachment), do: false

  defp valid_non_negative_integer_or_nil?(nil), do: true
  defp valid_non_negative_integer_or_nil?(value) when is_integer(value) and value >= 0, do: true
  defp valid_non_negative_integer_or_nil?(_), do: false

  defp valid_positive_integer_or_nil?(nil), do: true
  defp valid_positive_integer_or_nil?(value) when is_integer(value) and value > 0, do: true
  defp valid_positive_integer_or_nil?(_), do: false

  defp valid_boolean_or_nil?(nil), do: true
  defp valid_boolean_or_nil?(value) when is_boolean(value), do: true
  defp valid_boolean_or_nil?(_), do: false

  defp valid_optional_binary?(value, opts \\ [])

  defp valid_optional_binary?(nil, opts), do: Keyword.get(opts, :required?, false) != true

  defp valid_optional_binary?(value, opts) when is_binary(value) do
    allow_empty? = Keyword.get(opts, :allow_empty?, true)
    required? = Keyword.get(opts, :required?, false)
    trimmed = String.trim(value)

    cond do
      not Elektrine.Strings.present?(trimmed) and required? ->
        false

      not Elektrine.Strings.present?(trimmed) and !allow_empty? ->
        false

      true ->
        true
    end
  end

  defp valid_optional_binary?(_value, _opts), do: false

  defp valid_optional_iso8601?(nil), do: true
  defp valid_optional_iso8601?(value), do: valid_iso8601?(value)

  defp valid_actor_payload?(actor) when is_map(actor) do
    uri = normalize_actor_identity_field(actor, "uri")
    id = normalize_actor_identity_field(actor, "id")
    username = normalize_actor_identity_field(actor, "username")
    domain = normalize_actor_identity_field(actor, "domain")
    handle = normalize_actor_identity_field(actor, "handle")

    canonical_handle =
      if is_binary(username) and is_binary(domain),
        do: "#{String.downcase(username)}@#{String.downcase(domain)}"

    cond do
      !valid_absolute_http_uri?(uri) ->
        false

      !is_binary(username) ->
        false

      !is_binary(domain) ->
        false

      !is_binary(handle) ->
        false

      is_binary(id) and !valid_absolute_http_uri?(id) ->
        false

      String.downcase(handle) != canonical_handle ->
        false

      true ->
        true
    end
  end

  defp valid_actor_payload?(_actor), do: false

  defp normalize_actor_identity_field(actor, key) when is_map(actor) do
    case Map.get(actor, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp valid_absolute_http_uri?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_absolute_http_uri?(_value), do: false

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
    Elektrine.Strings.present?(value)
  end

  defp non_empty_binary?(_), do: false

  defp normalize_envelope_for_signing(envelope) when is_map(envelope) do
    case Map.get(envelope, "event_type") do
      event_type when is_binary(event_type) ->
        Map.put(envelope, "event_type", canonical_event_type(event_type))

      _ ->
        envelope
    end
  end

  defp normalize_envelope_for_signing(envelope), do: envelope

  defp canonical_event_signature_payload(envelope) when is_map(envelope) do
    canonical_event_signature_payload(envelope, @protocol_id)
  end

  defp canonical_event_signature_payload(envelope, protocol_identifier) when is_map(envelope) do
    payload = envelope["payload"] || %{}
    idempotency_key = envelope["idempotency_key"]

    [
      protocol_identifier,
      to_string(envelope["protocol_version"] || ""),
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
      not Elektrine.Strings.present?(trimmed) -> "/"
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
