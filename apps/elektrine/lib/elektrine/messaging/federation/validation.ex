defmodule Elektrine.Messaging.Federation.Validation do
  @moduledoc false

  alias Elektrine.Messaging.ArblargSDK

  def validate_snapshot_payload(payload, remote_domain, context)
      when is_map(payload) and is_binary(remote_domain) and is_map(context) do
    origin_domain = payload["origin_domain"]
    server = payload["server"] || %{}
    channels = payload["channels"] || []
    messages = payload["messages"] || []
    governance = payload["governance"]
    stream_positions = payload["stream_positions"]
    reactions = payload["reactions"] || []
    read_cursors = payload["read_cursors"] || []
    message_deletions = payload["message_deletions"] || []
    extensions = payload["extensions"] || []

    governance_entry_count =
      context
      |> call(:snapshot_governance_entries, [governance])
      |> length()

    with true <- payload["version"] == 1 or {:error, :unsupported_version},
         true <- origin_domain == remote_domain or {:error, :origin_domain_mismatch},
         true <- is_map(server) or {:error, :invalid_server_payload},
         true <-
           (is_binary(server["id"]) and is_binary(server["name"])) or
             {:error, :invalid_server_payload},
         true <- is_list(channels) or {:error, :invalid_payload},
         true <- is_list(messages) or {:error, :invalid_payload},
         true <- is_list(reactions) or {:error, :invalid_payload},
         true <- is_list(read_cursors) or {:error, :invalid_payload},
         true <- is_list(message_deletions) or {:error, :invalid_payload},
         true <- is_list(extensions) or {:error, :invalid_payload},
         true <- is_map(governance) or {:error, :invalid_snapshot_governance},
         true <- snapshot_governance_present?(payload) or {:error, :invalid_snapshot_governance},
         true <-
           snapshot_governance_list?(governance, "memberships") or
             {:error, :invalid_snapshot_governance},
         true <-
           snapshot_governance_list?(governance, "invites") or
             {:error, :invalid_snapshot_governance},
         true <-
           snapshot_governance_list?(governance, "bans") or
             {:error, :invalid_snapshot_governance},
         true <- is_list(stream_positions) or {:error, :invalid_snapshot_stream_positions},
         true <-
           snapshot_stream_positions_present?(payload) or
             {:error, :invalid_snapshot_stream_positions},
         true <- stream_positions != [] or {:error, :invalid_snapshot_stream_positions},
         true <-
           length(channels) <= call(context, :snapshot_channel_limit, []) or
             {:error, :snapshot_limit_exceeded},
         true <-
           length(messages) <= call(context, :snapshot_message_limit, []) or
             {:error, :snapshot_limit_exceeded},
         true <-
           governance_entry_count <= call(context, :snapshot_governance_limit, []) or
             {:error, :snapshot_limit_exceeded},
         :ok <- validate_snapshot_signature(payload, remote_domain, context),
         :ok <- validate_snapshot_message_actors(messages, remote_domain, context),
         :ok <- validate_snapshot_origin_owned_identifiers(payload, remote_domain),
         :ok <- validate_snapshot_stream_positions(stream_positions, remote_domain),
         :ok <- validate_snapshot_governance_shape(governance, remote_domain, context),
         :ok <- validate_snapshot_reactions(reactions, remote_domain, context),
         :ok <- validate_snapshot_read_cursors(read_cursors, remote_domain, context),
         :ok <- validate_snapshot_message_deletions(message_deletions, remote_domain, context),
         :ok <- validate_snapshot_extensions(extensions, remote_domain, context) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_payload}
    end
  end

  def validate_snapshot_payload(_payload, _remote_domain, _context),
    do: {:error, :invalid_payload}

  def validate_event_payload(payload, remote_domain, context)
      when is_map(payload) and is_binary(remote_domain) and is_map(context) do
    payload = call(context, :normalize_incoming_event_payload, [payload])

    if payload["origin_domain"] != remote_domain do
      {:error, :origin_domain_mismatch}
    else
      case ArblargSDK.validate_event_envelope(payload) do
        :ok ->
          case maybe_require_event_signature(payload) do
            :ok ->
              with :ok <- maybe_verify_envelope_signature(payload, remote_domain, context),
                   :ok <- validate_origin_bound_actors(payload, remote_domain, context),
                   :ok <- validate_origin_owned_identifiers(payload, remote_domain, context) do
                validate_stream_origin(payload["stream_id"], remote_domain)
              end

            error ->
              error
          end

        {:error, :unsupported_version} ->
          {:error, :unsupported_version}

        {:error, :unsupported_protocol} ->
          {:error, :unsupported_protocol}

        {:error, :unsupported_event_type} ->
          {:error, :unsupported_event_type}

        {:error, :invalid_event_id} ->
          {:error, :invalid_event_id}

        {:error, :invalid_stream_id} ->
          {:error, :invalid_stream_id}

        {:error, :invalid_sequence} ->
          {:error, :invalid_sequence}

        {:error, :invalid_idempotency_key} ->
          {:error, :invalid_idempotency_key}

        {:error, :invalid_event_payload} ->
          {:error, :invalid_event_payload}

        {:error, :invalid_signature} ->
          {:error, :invalid_event_signature}

        {:error, _} ->
          {:error, :invalid_payload}
      end
    end
  end

  def validate_event_payload(_payload, _remote_domain, _context), do: {:error, :invalid_payload}

  def validate_snapshot_governance_payload(event_type, payload, remote_domain, context)
      when is_binary(event_type) and is_map(payload) and is_binary(remote_domain) and
             is_map(context) do
    with :ok <- ArblargSDK.validate_event_payload(event_type, payload),
         :ok <- validate_snapshot_governance_actors(event_type, payload, remote_domain, context),
         :ok <-
           validate_origin_owned_identifiers_in_event_data(
             event_type,
             payload,
             remote_domain,
             context
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_snapshot_governance_payload(_event_type, _payload, _remote_domain, _context),
    do: {:error, :invalid_snapshot_governance}

  defp validate_snapshot_governance_actors("membership.upsert", payload, _remote_domain, _context)
       when is_map(payload) do
    actor = get_in(payload, ["membership", "actor"])

    if actor_domain_matches_origin?(actor, actor_origin_domain(actor)) do
      :ok
    else
      {:error, :origin_actor_domain_mismatch}
    end
  end

  defp validate_snapshot_governance_actors(event_type, payload, remote_domain, context) do
    validate_snapshot_origin_bound_actors_in_event_data(
      event_type,
      payload,
      remote_domain,
      context
    )
  end

  def validate_origin_bound_actors_in_event_data(event_type, data, remote_domain, context)
      when is_binary(event_type) and is_map(data) and is_binary(remote_domain) and is_map(context) do
    actors =
      event_type
      |> normalized_event_name()
      |> origin_bound_actors(data)

    if Enum.all?(actors, &actor_domain_matches_origin?(&1, remote_domain)) do
      :ok
    else
      {:error, :origin_actor_domain_mismatch}
    end
  end

  def validate_origin_bound_actors_in_event_data(_event_type, _data, _remote_domain, _context),
    do: {:error, :invalid_payload}

  def validate_origin_owned_identifiers_in_event_data(event_type, data, remote_domain, context)
      when is_binary(event_type) and is_map(data) and is_binary(remote_domain) and is_map(context) do
    identifiers =
      event_type
      |> normalized_event_name()
      |> origin_owned_event_identifiers(data, context)

    if Enum.all?(identifiers, &origin_owned_absolute_uri?(&1, remote_domain)) do
      :ok
    else
      {:error, :origin_identifier_host_mismatch}
    end
  end

  def validate_origin_owned_identifiers_in_event_data(
        _event_type,
        _data,
        _remote_domain,
        _context
      ),
      do: {:error, :invalid_payload}

  defp maybe_verify_envelope_signature(payload, remote_domain, context) do
    case payload["signature"] do
      %{} ->
        case call(context, :incoming_peer, [remote_domain]) do
          %{} = peer ->
            key_lookup =
              fn key_id ->
                call(context, :incoming_verification_materials_for_key_id, [peer, key_id])
              end

            if ArblargSDK.verify_event_envelope_signature(payload, key_lookup) do
              :ok
            else
              {:error, :invalid_event_signature}
            end

          _ ->
            {:error, :unknown_peer}
        end

      _ ->
        :ok
    end
  end

  defp validate_origin_bound_actors(payload, remote_domain, context)
       when is_map(payload) and is_binary(remote_domain) do
    event_type = ArblargSDK.canonical_event_type(payload["event_type"])
    data = payload["payload"] || %{}

    validate_origin_bound_actors_in_event_data(event_type, data, remote_domain, context)
  end

  defp validate_origin_bound_actors(_payload, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp origin_bound_actors(event_type, data) when is_binary(event_type) and is_map(data) do
    case event_type do
      "message.create" ->
        [get_in(data, ["message", "sender"])]

      "message.update" ->
        [get_in(data, ["message", "sender"])]

      "reaction.add" ->
        [get_in(data, ["reaction", "actor"])]

      "reaction.remove" ->
        [get_in(data, ["reaction", "actor"])]

      "read.cursor" ->
        [data["actor"]]

      "membership.upsert" ->
        [get_in(data, ["membership", "actor"])]

      "invite.upsert" ->
        [get_in(data, ["invite", "actor"])]

      "ban.upsert" ->
        [get_in(data, ["ban", "actor"])]

      "role.upsert" ->
        [data["actor"]]

      "role.assignment.upsert" ->
        [data["actor"]]

      "permission.overwrite.upsert" ->
        [data["actor"]]

      "thread.upsert" ->
        [get_in(data, ["thread", "owner"])]

      "thread.archive" ->
        [data["actor"]]

      "presence.update" ->
        [get_in(data, ["presence", "actor"])]

      "typing.start" ->
        [data["actor"]]

      "typing.stop" ->
        [data["actor"]]

      "moderation.action.recorded" ->
        [get_in(data, ["action", "actor"])]

      "dm.message.create" ->
        [get_in(data, ["dm", "sender"]), get_in(data, ["message", "sender"])]

      "dm.call.invite" ->
        [get_in(data, ["dm", "sender"]), get_in(data, ["dm", "recipient"]), get_in(data, ["call", "actor"])]

      "dm.call.accept" ->
        [get_in(data, ["dm", "sender"]), get_in(data, ["dm", "recipient"]), data["actor"]]

      "dm.call.reject" ->
        [get_in(data, ["dm", "sender"]), get_in(data, ["dm", "recipient"]), data["actor"]]

      "dm.call.end" ->
        [get_in(data, ["dm", "sender"]), get_in(data, ["dm", "recipient"]), data["actor"]]

      "dm.call.signal" ->
        [get_in(data, ["dm", "sender"]), get_in(data, ["dm", "recipient"]), data["actor"]]

      _ ->
        []
    end
  end

  defp actor_domain_matches_origin?(nil, _remote_domain), do: true

  defp actor_domain_matches_origin?(actor, remote_domain)
       when is_map(actor) and is_binary(remote_domain) do
    actor_domain = normalize_optional_string(actor["domain"] || actor[:domain])
    actor_uri = normalize_optional_string(actor["uri"] || actor[:uri])

    case actor_domain do
      nil ->
        false

      normalized_actor_domain ->
        String.downcase(normalized_actor_domain) == String.downcase(remote_domain) and
          origin_owned_absolute_uri?(actor_uri, remote_domain)
    end
  end

  defp actor_domain_matches_origin?(_actor, _remote_domain), do: false

  defp validate_origin_owned_identifiers(payload, remote_domain, context)
       when is_map(payload) and is_binary(remote_domain) do
    event_type = ArblargSDK.canonical_event_type(payload["event_type"])
    data = payload["payload"] || %{}

    validate_origin_owned_identifiers_in_event_data(event_type, data, remote_domain, context)
  end

  defp validate_origin_owned_identifiers(_payload, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp validate_stream_origin(stream_id, remote_domain)
       when is_binary(stream_id) and is_binary(remote_domain) do
    case String.split(stream_id, ":", parts: 2) do
      ["channel", identifier] when identifier != "" ->
        if absolute_http_uri?(identifier) do
          :ok
        else
          {:error, :origin_stream_host_mismatch}
        end

      [scope, identifier] when scope in ["server", "dm"] and identifier != "" ->
        if origin_owned_absolute_uri?(identifier, remote_domain) do
          :ok
        else
          {:error, :origin_stream_host_mismatch}
        end

      _ ->
        {:error, :invalid_stream_id}
    end
  end

  defp validate_stream_origin(_stream_id, _remote_domain), do: {:error, :invalid_stream_id}

  defp origin_owned_event_identifiers(event_type, data, context)
       when is_binary(event_type) and is_map(data) and is_map(context) do
    base_context_ids =
      if multi_origin_room_event_type?(event_type) or
           room_scoped_presence_event_type?(event_type, data) do
        []
      else
        [
          call(context, :event_server_id, [data]),
          call(context, :event_channel_id, [data])
        ]
        |> Enum.filter(&is_binary/1)
      end

    event_specific_ids =
      case event_type do
        "server.upsert" ->
          [get_in(data, ["server", "id"]) | Enum.map(data["channels"] || [], &Map.get(&1, "id"))]

        "message.create" ->
          [get_in(data, ["message", "id"])]

        "message.update" ->
          [get_in(data, ["message", "id"])]

        "message.delete" ->
          [data["message_id"]]

        "dm.message.create" ->
          [
            get_in(data, ["dm", "id"]),
            get_in(data, ["message", "id"]),
            get_in(data, ["message", "dm_id"])
          ]

        "dm.call.invite" ->
          [
            get_in(data, ["dm", "id"]),
            get_in(data, ["call", "id"]),
            get_in(data, ["call", "dm_id"])
          ]

        "dm.call.accept" ->
          [
            get_in(data, ["dm", "id"]),
            data["call_id"]
          ]

        "dm.call.reject" ->
          [
            get_in(data, ["dm", "id"]),
            data["call_id"]
          ]

        "dm.call.end" ->
          [
            get_in(data, ["dm", "id"]),
            data["call_id"]
          ]

        "dm.call.signal" ->
          [
            get_in(data, ["dm", "id"]),
            data["call_id"]
          ]

        _ ->
          []
      end

    (base_context_ids ++ event_specific_ids)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp origin_owned_event_identifiers(_event_type, _data, _context), do: []

  defp validate_snapshot_origin_owned_identifiers(payload, remote_domain)
       when is_map(payload) and is_binary(remote_domain) do
    server_ids = [get_in(payload, ["server", "id"])]
    channel_ids = Enum.map(payload["channels"] || [], &Map.get(&1, "id"))
    message_channel_ids = Enum.map(payload["messages"] || [], &Map.get(&1, "channel_id"))

    deletion_channel_ids =
      Enum.map(payload["message_deletions"] || [], &get_in(&1, ["refs", "channel_id"]))

    identifiers =
      (server_ids ++ channel_ids ++ message_channel_ids ++ deletion_channel_ids)
      |> Enum.filter(&is_binary/1)

    if Enum.all?(identifiers, &origin_owned_absolute_uri?(&1, remote_domain)) do
      :ok
    else
      {:error, :origin_identifier_host_mismatch}
    end
  end

  defp validate_snapshot_origin_owned_identifiers(_payload, _remote_domain),
    do: {:error, :invalid_payload}

  defp validate_snapshot_message_actors(messages, remote_domain, context)
       when is_list(messages) and is_binary(remote_domain) and is_map(context) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case snapshot_message_origin_valid?(message, remote_domain) do
        true -> {:cont, :ok}
        false -> {:halt, {:error, :origin_actor_domain_mismatch}}
      end
    end)
  end

  defp validate_snapshot_message_actors(_messages, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp validate_snapshot_governance_shape(governance, remote_domain, context)
       when is_map(governance) and is_binary(remote_domain) and is_map(context) do
    call(context, :snapshot_governance_entries, [governance])
    |> Enum.reduce_while(:ok, fn {event_type, payload}, :ok ->
      case validate_snapshot_governance_payload(event_type, payload, remote_domain, context) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_snapshot_governance_shape(_governance, _remote_domain, _context),
    do: {:error, :invalid_snapshot_governance}

  defp validate_snapshot_reactions(reactions, remote_domain, context)
       when is_list(reactions) and is_binary(remote_domain) and is_map(context) do
    validate_snapshot_event_list(
      reactions,
      "reaction.add",
      remote_domain,
      context,
      :invalid_payload
    )
  end

  defp validate_snapshot_reactions(_reactions, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp validate_snapshot_read_cursors(read_cursors, remote_domain, context)
       when is_list(read_cursors) and is_binary(remote_domain) and is_map(context) do
    validate_snapshot_event_list(
      read_cursors,
      "read.cursor",
      remote_domain,
      context,
      :invalid_payload
    )
  end

  defp validate_snapshot_read_cursors(_read_cursors, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp validate_snapshot_message_deletions(message_deletions, remote_domain, context)
       when is_list(message_deletions) and is_binary(remote_domain) and is_map(context) do
    validate_snapshot_event_list(
      message_deletions,
      "message.delete",
      remote_domain,
      context,
      :invalid_payload
    )
  end

  defp validate_snapshot_message_deletions(_message_deletions, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp validate_snapshot_extensions(extensions, remote_domain, context)
       when is_list(extensions) and is_binary(remote_domain) and is_map(context) do
    Enum.reduce_while(extensions, :ok, fn extension_entry, :ok ->
      case extension_entry do
        %{"event_type" => event_type, "payload" => payload}
        when is_binary(event_type) and is_map(payload) ->
          case validate_snapshot_event_entry(event_type, payload, remote_domain, context) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _ ->
          {:halt, {:error, :invalid_payload}}
      end
    end)
  end

  defp validate_snapshot_extensions(_extensions, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp validate_snapshot_stream_positions(stream_positions, remote_domain)
       when is_list(stream_positions) and is_binary(remote_domain) do
    if Enum.all?(stream_positions, &valid_snapshot_stream_position?(&1, remote_domain)) do
      :ok
    else
      {:error, :invalid_snapshot_stream_positions}
    end
  end

  defp validate_snapshot_stream_positions(_stream_positions, _remote_domain),
    do: {:error, :invalid_snapshot_stream_positions}

  defp validate_snapshot_event_list(entries, event_type, remote_domain, context, error_reason)
       when is_list(entries) and is_binary(event_type) and is_binary(remote_domain) and
              is_map(context) do
    Enum.reduce_while(entries, :ok, fn payload, :ok ->
      case validate_snapshot_event_entry(event_type, payload, remote_domain, context) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, error_reason}}
      end
    end)
  end

  defp validate_snapshot_event_entry(event_type, payload, remote_domain, context)
       when is_binary(event_type) and is_map(payload) and is_binary(remote_domain) and
              is_map(context) do
    with :ok <- ArblargSDK.validate_event_payload(event_type, payload),
         :ok <-
           validate_snapshot_origin_bound_actors_in_event_data(
             event_type,
             payload,
             remote_domain,
             context
           ),
         :ok <-
           validate_origin_owned_identifiers_in_event_data(
             event_type,
             payload,
             remote_domain,
             context
           ) do
      :ok
    end
  end

  defp validate_snapshot_event_entry(_event_type, _payload, _remote_domain, _context),
    do: {:error, :invalid_payload}

  defp validate_snapshot_origin_bound_actors_in_event_data(
         event_type,
         data,
         remote_domain,
         context
       )
       when is_binary(event_type) and is_map(data) and is_binary(remote_domain) and
              is_map(context) do
    normalized_event_type = normalized_event_name(event_type)

    if multi_origin_room_event_type?(normalized_event_type) do
      actors = origin_bound_actors(normalized_event_type, data)

      if Enum.all?(actors, &snapshot_actor_origin_valid?/1) do
        :ok
      else
        {:error, :origin_actor_domain_mismatch}
      end
    else
      validate_origin_bound_actors_in_event_data(event_type, data, remote_domain, context)
    end
  end

  defp validate_snapshot_origin_bound_actors_in_event_data(
         _event_type,
         _data,
         _remote_domain,
         _context
       ),
       do: {:error, :invalid_payload}

  defp validate_snapshot_signature(payload, remote_domain, context)
       when is_map(payload) and is_binary(remote_domain) and is_map(context) do
    with %{"algorithm" => algorithm, "key_id" => key_id, "value" => value} <- payload["signature"],
         true <- algorithm == ArblargSDK.signature_algorithm(),
         true <- is_binary(key_id) and String.trim(key_id) != "",
         true <- is_binary(value) and String.trim(value) != "",
         %{} = peer <- call(context, :incoming_peer, [remote_domain]) do
      verification_materials =
        call(context, :incoming_verification_materials_for_key_id, [peer, key_id])

      if Enum.any?(verification_materials, fn material ->
           ArblargSDK.verify_payload_signature(
             call(context, :snapshot_signature_payload, [payload]),
             material,
             value
           )
         end) do
        :ok
      else
        {:error, :invalid_snapshot_signature}
      end
    else
      false -> {:error, :invalid_snapshot_signature}
      nil -> {:error, :unknown_peer}
      _ -> {:error, :invalid_snapshot_signature}
    end
  end

  defp validate_snapshot_signature(_payload, _remote_domain, _context),
    do: {:error, :invalid_snapshot_signature}

  defp origin_owned_absolute_uri?(value, remote_domain)
       when is_binary(value) and is_binary(remote_domain) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        host_belongs_to_domain?(host, remote_domain)

      _ ->
        false
    end
  end

  defp origin_owned_absolute_uri?(_value, _remote_domain), do: false

  defp absolute_http_uri?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp absolute_http_uri?(_value), do: false

  defp host_belongs_to_domain?(host, remote_domain)
       when is_binary(host) and is_binary(remote_domain) do
    normalized_host = String.downcase(host)
    normalized_domain = String.downcase(remote_domain)

    normalized_host == normalized_domain or
      String.ends_with?(normalized_host, "." <> normalized_domain)
  end

  defp host_belongs_to_domain?(_host, _remote_domain), do: false

  defp maybe_require_event_signature(payload) when is_map(payload) do
    if is_map(payload["signature"]), do: :ok, else: {:error, :invalid_event_signature}
  end

  defp maybe_require_event_signature(_payload), do: {:error, :invalid_event_signature}

  defp snapshot_governance_present?(payload) when is_map(payload) do
    Map.has_key?(payload, "governance") or Map.has_key?(payload, :governance)
  end

  defp snapshot_governance_present?(_payload), do: false

  defp snapshot_governance_list?(governance, key) when is_map(governance) and is_binary(key) do
    Map.has_key?(governance, key) and is_list(governance[key])
  end

  defp snapshot_governance_list?(_governance, _key), do: false

  defp snapshot_stream_positions_present?(payload) when is_map(payload) do
    Map.has_key?(payload, "stream_positions") or Map.has_key?(payload, :stream_positions)
  end

  defp snapshot_stream_positions_present?(_payload), do: false

  defp valid_snapshot_stream_position?(position, remote_domain)
       when is_map(position) and is_binary(remote_domain) do
    origin_domain =
      normalize_optional_string(position["origin_domain"] || position[:origin_domain]) ||
        remote_domain

    stream_id = position["stream_id"] || position[:stream_id]
    last_sequence = position["last_sequence"] || position[:last_sequence]

    case {origin_domain, stream_id, last_sequence} do
      {origin_domain, stream_id, last_sequence}
      when is_binary(origin_domain) and is_binary(stream_id) and is_integer(last_sequence) and
             last_sequence >= 0 ->
        case String.split(stream_id, ":", parts: 2) do
          ["channel", identifier] when identifier != "" ->
            absolute_http_uri?(identifier)

          [scope, identifier] when scope in ["server", "dm"] and identifier != "" ->
            origin_owned_absolute_uri?(identifier, origin_domain)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp valid_snapshot_stream_position?(_position, _remote_domain), do: false

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_value), do: nil

  defp snapshot_message_origin_valid?(message, snapshot_origin_domain)
       when is_map(message) and is_binary(snapshot_origin_domain) do
    message_id = normalize_optional_string(message["id"])

    cond do
      !is_binary(message_id) ->
        false

      is_map(message["sender"]) ->
        sender_domain = actor_origin_domain(message["sender"])

        is_binary(sender_domain) and
          actor_domain_matches_origin?(message["sender"], sender_domain) and
          origin_owned_absolute_uri?(message_id, sender_domain)

      true ->
        origin_owned_absolute_uri?(message_id, snapshot_origin_domain)
    end
  end

  defp snapshot_message_origin_valid?(_message, _snapshot_origin_domain), do: false

  defp snapshot_actor_origin_valid?(nil), do: true

  defp snapshot_actor_origin_valid?(actor) when is_map(actor) do
    case actor_origin_domain(actor) do
      origin_domain when is_binary(origin_domain) ->
        actor_domain_matches_origin?(actor, origin_domain)

      _ ->
        false
    end
  end

  defp snapshot_actor_origin_valid?(_actor), do: false

  defp actor_origin_domain(actor) when is_map(actor) do
    normalize_optional_string(actor["domain"] || actor[:domain]) ||
      actor
      |> actor_uri()
      |> actor_uri_host()
  end

  defp actor_origin_domain(_actor), do: nil

  defp actor_uri(actor) when is_map(actor) do
    normalize_optional_string(actor["uri"] || actor[:uri] || actor["id"] || actor[:id])
  end

  defp actor_uri(_actor), do: nil

  defp actor_uri_host(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) and host != "" -> String.downcase(host)
      _ -> nil
    end
  end

  defp actor_uri_host(_uri), do: nil

  defp room_participation_event_type?(event_type)
       when event_type in [
              "message.create",
              "message.update",
              "message.delete",
              "reaction.add",
              "reaction.remove",
              "read.cursor",
              "membership.upsert",
              "typing.start",
              "typing.stop"
            ],
       do: true

  defp room_participation_event_type?(_event_type), do: false

  defp shared_room_governance_event_type?(event_type)
       when event_type in [
              "invite.upsert",
              "ban.upsert",
              "role.upsert",
              "role.assignment.upsert",
              "permission.overwrite.upsert",
              "thread.upsert",
              "thread.archive",
              "moderation.action.recorded"
            ],
       do: true

  defp shared_room_governance_event_type?(_event_type), do: false

  defp multi_origin_room_event_type?(event_type) do
    normalized_event_type = normalized_event_name(event_type)

    room_participation_event_type?(normalized_event_type) or
      shared_room_governance_event_type?(normalized_event_type)
  end

  defp room_scoped_presence_event_type?(event_type, data)
       when is_binary(event_type) and is_map(data) do
    normalized_event_name(event_type) == "presence.update" and
      (is_binary(get_in(data, ["refs", "channel_id"])) or
         is_binary(get_in(data, ["channel", "id"])))
  end

  defp room_scoped_presence_event_type?(_event_type, _data), do: false

  defp normalized_event_name(event_type) when is_binary(event_type) do
    canonical_event_type = ArblargSDK.canonical_event_type(event_type)
    Map.get(ArblargSDK.schema_bindings(), canonical_event_type, canonical_event_type)
  end

  defp normalized_event_name(event_type), do: event_type

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
