defmodule Elektrine.Messaging.ArblargProfiles do
  @moduledoc """
  Arblarg profile and extension registry metadata.

  This module codifies interoperability discipline for Arblarg:
  - one mandatory core profile
  - optional community extension profile
  - strict extension registry with namespaces and rejection rules
  - conformance-claim gating
  """

  alias Elektrine.Messaging.ArblargSDK

  @core_profile_id "arblarg-core/1.0"
  @core_profile_description "Mandatory Arblarg core interoperability profile"
  @community_profile_id "arblarg-community/1.0"

  @community_profile_description "Optional community profile requiring roles, permissions, threads, presence, and moderation extensions"

  @conformance_suite_version "2026.02"
  @extension_conformance_suite_version "2026.02-ext"
  @conformance_test_command "mix test apps/elektrine_web/test/elektrine_web/controllers/arblarg_conformance_test.exs"

  @community_conformance_test_command "mix test apps/elektrine/test/elektrine/messaging/arblarg_extension_conformance_test.exs"

  @extension_definitions [
    %{
      urn: "urn:arblarg:ext:bootstrap:1",
      version: 1,
      stability: "stable",
      required: false,
      events: [ArblargSDK.bootstrap_server_upsert_event_type()],
      fallback: "reject_unsupported_event_type",
      gate: "optional",
      env_flag: "MESSAGING_FEDERATION_CONFORMANCE_CORE_PASSED",
      test_command: @conformance_test_command,
      profile_requirement: nil
    },
    %{
      urn: "urn:arblarg:ext:roles:1",
      version: 1,
      stability: "experimental",
      required: false,
      events: ArblargSDK.roles_event_types(),
      fallback: "reject_unsupported_event_type",
      gate: "required_for_arblarg_community_1_0",
      env_flag: "MESSAGING_FEDERATION_CONFORMANCE_EXT_ROLES_PASSED",
      test_command: @community_conformance_test_command,
      profile_requirement: @community_profile_id
    },
    %{
      urn: "urn:arblarg:ext:permissions:1",
      version: 1,
      stability: "experimental",
      required: false,
      events: ArblargSDK.permissions_event_types(),
      fallback: "reject_unsupported_event_type",
      gate: "required_for_arblarg_community_1_0",
      env_flag: "MESSAGING_FEDERATION_CONFORMANCE_EXT_PERMISSIONS_PASSED",
      test_command: @community_conformance_test_command,
      profile_requirement: @community_profile_id
    },
    %{
      urn: "urn:arblarg:ext:threads:1",
      version: 1,
      stability: "experimental",
      required: false,
      events: ArblargSDK.threads_event_types(),
      fallback: "reject_unsupported_event_type",
      gate: "required_for_arblarg_community_1_0",
      env_flag: "MESSAGING_FEDERATION_CONFORMANCE_EXT_THREADS_PASSED",
      test_command: @community_conformance_test_command,
      profile_requirement: @community_profile_id
    },
    %{
      urn: "urn:arblarg:ext:presence:1",
      version: 1,
      stability: "experimental",
      required: false,
      events: ArblargSDK.presence_event_types(),
      fallback: "reject_unsupported_event_type",
      gate: "required_for_arblarg_community_1_0",
      env_flag: "MESSAGING_FEDERATION_CONFORMANCE_EXT_PRESENCE_PASSED",
      test_command: @community_conformance_test_command,
      profile_requirement: @community_profile_id
    },
    %{
      urn: "urn:arblarg:ext:moderation:1",
      version: 1,
      stability: "experimental",
      required: false,
      events: ArblargSDK.moderation_event_types(),
      fallback: "reject_unsupported_event_type",
      gate: "required_for_arblarg_community_1_0",
      env_flag: "MESSAGING_FEDERATION_CONFORMANCE_EXT_MODERATION_PASSED",
      test_command: @community_conformance_test_command,
      profile_requirement: @community_profile_id
    },
    %{
      urn: "urn:arblarg:ext:dm:1",
      version: 1,
      stability: "experimental",
      required: false,
      events: ArblargSDK.dm_event_types(),
      fallback: "reject_unsupported_event_type",
      gate: "optional",
      env_flag: nil,
      test_command: nil,
      profile_requirement: nil
    },
    %{
      urn: "urn:arblarg:ext:voice:1",
      version: 1,
      stability: "experimental",
      required: false,
      events: ArblargSDK.voice_event_types(),
      fallback: "reject_unsupported_event_type",
      gate: "optional",
      env_flag: nil,
      test_command: nil,
      profile_requirement: nil
    }
  ]

  @community_required_extensions @extension_definitions
                                 |> Enum.filter(
                                   &(&1.profile_requirement == @community_profile_id)
                                 )
                                 |> Enum.map(& &1.urn)

  @extension_definitions_by_event_type Enum.reduce(@extension_definitions, %{}, fn definition,
                                                                                   acc ->
                                         Enum.reduce(definition.events, acc, fn event_type,
                                                                                event_acc ->
                                           Map.put(event_acc, event_type, definition)
                                         end)
                                       end)

  def core_profile_id, do: @core_profile_id
  def core_profile_description, do: @core_profile_description
  def community_profile_id, do: @community_profile_id
  def community_profile_description, do: @community_profile_description
  def conformance_suite_version, do: @conformance_suite_version
  def extension_conformance_suite_version, do: @extension_conformance_suite_version
  def conformance_test_command, do: @conformance_test_command
  def community_conformance_test_command, do: @community_conformance_test_command
  def community_required_extensions, do: @community_required_extensions
  def extension_definition_for_event_type(event_type), do: extension_definition(event_type)

  def extension_urn_for_event_type(event_type) do
    case extension_definition(event_type) do
      %{urn: urn} -> urn
      _ -> nil
    end
  end

  def required_profile_for_event_type(event_type) do
    case extension_definition(event_type) do
      %{profile_requirement: profile_requirement} -> profile_requirement
      _ -> nil
    end
  end

  def core_event_types, do: ArblargSDK.core_event_types()

  def extension_registry(opts \\ []) do
    Enum.map(@extension_definitions, &build_extension_entry(&1, opts))
  end

  def extension_event_types do
    @extension_definitions
    |> Enum.flat_map(&Map.get(&1, :events, []))
    |> Enum.uniq()
  end

  def profile_badges(opts \\ []) do
    [core_profile_badge(opts), community_profile_badge(opts)]
  end

  def passing_profile_claims(opts \\ []) do
    profile_badges(opts)
    |> Enum.filter(&(&1["status"] == "passing"))
    |> Enum.map(& &1["id"])
  end

  def conformance_core_passed?(opts \\ []) do
    if Keyword.has_key?(opts, :core_passed?) do
      Keyword.get(opts, :core_passed?) == true
    else
      messaging_federation_config()
      |> Keyword.get(:conformance_core_passed, false)
      |> truthy?()
    end
  end

  def extension_conformance_passed?(urn, opts \\ [])

  def extension_conformance_passed?(urn, opts) when is_binary(urn) do
    extension_status =
      opts
      |> Keyword.get(:extension_statuses, %{})
      |> status_lookup(urn)

    cond do
      not is_nil(extension_status) ->
        truthy?(extension_status)

      urn == "urn:arblarg:ext:bootstrap:1" ->
        conformance_core_passed?(opts)

      true ->
        messaging_federation_config()
        |> Keyword.get(:conformance_extensions, %{})
        |> status_lookup(urn)
        |> truthy?()
    end
  end

  def extension_conformance_passed?(_urn, _opts), do: false

  def community_profile_passed?(opts \\ []) do
    if Keyword.has_key?(opts, :community_passed?) do
      Keyword.get(opts, :community_passed?) == true
    else
      conformance_core_passed?(opts) and
        Enum.all?(@community_required_extensions, &extension_conformance_passed?(&1, opts))
    end
  end

  defp core_profile_badge(opts) do
    status = if conformance_core_passed?(opts), do: "passing", else: "unverified"

    %{
      "id" => @core_profile_id,
      "description" => @core_profile_description,
      "required" => true,
      "status" => status,
      "suite_version" => @conformance_suite_version,
      "conformance_test_command" => @conformance_test_command,
      "required_events" => core_event_types(),
      "required_security" => %{
        "request_signature_algorithm" => ArblargSDK.signature_algorithm(),
        "event_signature_required" => true,
        "replay_protection_required" => true,
        "tls_required" => true
      }
    }
  end

  defp community_profile_badge(opts) do
    status = if community_profile_passed?(opts), do: "passing", else: "unverified"

    %{
      "id" => @community_profile_id,
      "description" => @community_profile_description,
      "required" => false,
      "status" => status,
      "suite_version" => @extension_conformance_suite_version,
      "conformance_test_command" => @community_conformance_test_command,
      "required_extensions" => @community_required_extensions,
      "required_events" =>
        @extension_definitions
        |> Enum.filter(&(&1.profile_requirement == @community_profile_id))
        |> Enum.flat_map(& &1.events)
        |> Enum.uniq(),
      "required_security" => %{
        "request_signature_algorithm" => ArblargSDK.signature_algorithm(),
        "event_signature_required" => true,
        "replay_protection_required" => true,
        "tls_required" => true
      }
    }
  end

  defp build_extension_entry(definition, opts) do
    status =
      if extension_conformance_passed?(definition.urn, opts), do: "passing", else: "unverified"

    %{
      "urn" => definition.urn,
      "version" => definition.version,
      "stability" => definition.stability,
      "required" => definition.required,
      "events" => definition.events,
      "fallback" => definition.fallback,
      "profile_requirement" => definition.profile_requirement,
      "conformance" => %{
        "status" => status,
        "suite_version" =>
          if(definition.urn == "urn:arblarg:ext:bootstrap:1",
            do: @conformance_suite_version,
            else: @extension_conformance_suite_version
          ),
        "test_command" => definition.test_command,
        "env_flag" => definition.env_flag,
        "gate" => definition.gate
      }
    }
  end

  defp extension_definition(event_type) when is_binary(event_type) do
    canonical_event_type = ArblargSDK.canonical_event_type(event_type)
    Map.get(@extension_definitions_by_event_type, canonical_event_type)
  end

  defp extension_definition(_event_type), do: nil

  defp messaging_federation_config do
    Application.get_env(:elektrine, :messaging_federation, [])
  end

  defp status_lookup(statuses, key) when is_map(statuses) do
    case Map.get(statuses, key) do
      nil ->
        statuses
        |> Map.keys()
        |> Enum.find(fn map_key -> is_atom(map_key) and Atom.to_string(map_key) == key end)
        |> case do
          nil -> nil
          atom_key -> Map.get(statuses, atom_key)
        end

      value ->
        value
    end
  end

  defp status_lookup(_statuses, _key), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_), do: false
end
