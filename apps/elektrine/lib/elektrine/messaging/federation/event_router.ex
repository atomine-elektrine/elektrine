defmodule Elektrine.Messaging.Federation.EventRouter do
  @moduledoc false

  alias Elektrine.Messaging.ArblargSDK

  alias Elektrine.Messaging.Federation.{
    Contexts,
    DirectMessages,
    ExtensionEvents,
    MirrorEvents,
    Peers,
    RequestAuth,
    Utils
  }

  @bootstrap_server_upsert_event_type ArblargSDK.bootstrap_server_upsert_event_type()
  @dm_message_create_event_type ArblargSDK.dm_message_create_event_type()

  def event_server_id(data) when is_map(data) do
    refs = data["refs"] || %{}
    get_in(data, ["server", "id"]) || refs["server_id"]
  end

  def event_server_id(_data), do: nil

  def event_channel_id(data) when is_map(data) do
    refs = data["refs"] || %{}
    get_in(data, ["channel", "id"]) || refs["channel_id"]
  end

  def event_channel_id(_data), do: nil

  def apply_event(@bootstrap_server_upsert_event_type, data, remote_domain) do
    apply_event("server.upsert", data, remote_domain)
  end

  def apply_event(@dm_message_create_event_type, data, remote_domain) do
    apply_event("dm.message.create", data, remote_domain)
  end

  def apply_event(event_type, data, remote_domain) when is_binary(event_type) do
    canonical_event_type = ArblargSDK.canonical_event_type(event_type)

    handler_event_type =
      Map.get(ArblargSDK.schema_bindings(), canonical_event_type, canonical_event_type)

    case DirectMessages.apply_event(
           handler_event_type,
           data,
           remote_domain,
           direct_message_context()
         ) do
      {:error, :unhandled_event_type} ->
        case MirrorEvents.apply_event(
               handler_event_type,
               data,
               remote_domain,
               mirror_event_context()
             ) do
          {:error, :unhandled_event_type} ->
            case ExtensionEvents.apply_event(
                   handler_event_type,
                   data,
                   remote_domain,
                   extension_event_context()
                 ) do
              {:error, :unhandled_event_type} ->
                {:error, :unsupported_event_type}

              result ->
                result
            end

          result ->
            result
        end

      result ->
        result
    end
  end

  def normalize_incoming_event_payload(payload) when is_map(payload), do: payload
  def normalize_incoming_event_payload(payload), do: payload

  defp direct_message_context, do: Contexts.direct_message()

  defp mirror_event_context do
    Contexts.mirror_event(%{
      parse_datetime: &Utils.parse_datetime/1,
      parse_int: &Utils.parse_int/2,
      actor_context: &actor_context/0
    })
  end

  defp extension_event_context do
    Contexts.extension_event(%{
      parse_datetime: &Utils.parse_datetime/1,
      actor_context: &actor_context/0
    })
  end

  defp actor_context do
    Contexts.actor(%{
      resolve_peer: &Peers.resolve_peer/1,
      incoming_verification_materials_for_key_id:
        &RequestAuth.incoming_verification_materials_for_key_id/2
    })
  end
end
