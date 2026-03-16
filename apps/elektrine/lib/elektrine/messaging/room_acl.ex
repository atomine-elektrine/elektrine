defmodule Elektrine.Messaging.RoomACL do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub.Actor

  alias Elektrine.Messaging.{
    ArblargSDK,
    Conversation,
    ConversationMember,
    FederationExtensionEvent,
    FederationMembershipState
  }

  alias Elektrine.Messaging.Federation.Utils
  alias Elektrine.Repo

  @builtin_roles %{
    "builtin:owner" => %{
      position: 100,
      permissions:
        MapSet.new([
          "manage_roles",
          "manage_permissions",
          "manage_moderation",
          "invite_members",
          "send_messages"
        ])
    },
    "builtin:admin" => %{
      position: 80,
      permissions:
        MapSet.new([
          "manage_roles",
          "manage_permissions",
          "manage_moderation",
          "invite_members",
          "send_messages"
        ])
    },
    "builtin:moderator" => %{
      position: 60,
      permissions: MapSet.new(["manage_moderation", "invite_members", "send_messages"])
    },
    "builtin:member" => %{
      position: 10,
      permissions: MapSet.new(["send_messages"])
    },
    "builtin:readonly" => %{
      position: 0,
      permissions: MapSet.new(["read_messages"])
    }
  }

  @base_role_ids %{
    "owner" => "builtin:owner",
    "admin" => "builtin:admin",
    "moderator" => "builtin:moderator",
    "member" => "builtin:member",
    "readonly" => "builtin:readonly"
  }

  @acl_event_types [
    ArblargSDK.canonical_event_type("role.upsert"),
    ArblargSDK.canonical_event_type("role.assignment.upsert"),
    ArblargSDK.canonical_event_type("permission.overwrite.upsert")
  ]

  @role_upsert_event_type ArblargSDK.canonical_event_type("role.upsert")
  @role_assignment_event_type ArblargSDK.canonical_event_type("role.assignment.upsert")
  @permission_overwrite_event_type ArblargSDK.canonical_event_type("permission.overwrite.upsert")

  def authorize_local_user_action(conversation_id, user_id, action)
      when is_integer(conversation_id) and is_integer(user_id) and is_atom(action) do
    with %Conversation{} = conversation <- Repo.get(Conversation, conversation_id),
         %ConversationMember{role: base_role} <-
           from(member in ConversationMember,
             where:
               member.conversation_id == ^conversation_id and member.user_id == ^user_id and
                 is_nil(member.left_at),
             limit: 1
           )
           |> Repo.one(),
         actor_uri when is_binary(actor_uri) <- local_actor_uri(user_id),
         true <- allowed?(conversation, base_role, actor_uri, action, %{}) do
      :ok
    else
      nil -> {:error, :unauthorized}
      false -> {:error, :unauthorized}
      _ -> {:error, :unauthorized}
    end
  end

  def authorize_local_user_action(_conversation_id, _user_id, _action),
    do: {:error, :unauthorized}

  def authorize_remote_actor_action(conversation, remote_actor_id, action, options \\ %{})

  def authorize_remote_actor_action(
        %Conversation{} = conversation,
        remote_actor_id,
        action,
        options
      )
      when is_integer(remote_actor_id) and is_atom(action) and is_map(options) do
    membership =
      Repo.get_by(FederationMembershipState,
        conversation_id: conversation.id,
        remote_actor_id: remote_actor_id,
        state: "active"
      )

    actor = Repo.get(Actor, remote_actor_id)

    with %FederationMembershipState{role: base_role} <- membership,
         %Actor{uri: actor_uri} when is_binary(actor_uri) <- actor,
         true <-
           allowed?(
             conversation,
             base_role,
             actor_uri,
             action,
             Map.put(options, :remote_actor_id, remote_actor_id)
           ) do
      :ok
    else
      nil -> {:error, :not_authorized_for_room}
      false -> {:error, :not_authorized_for_room}
      _ -> {:error, :not_authorized_for_room}
    end
  end

  def authorize_remote_actor_action(_conversation, _remote_actor_id, _action, _options),
    do: {:error, :not_authorized_for_room}

  defp allowed?(%Conversation{type: type}, _base_role, _actor_uri, action, _options)
       when type != "channel" and action in [:participate, :write, :send_messages],
       do: true

  defp allowed?(%Conversation{type: type}, _base_role, _actor_uri, _action, _options)
       when type != "channel",
       do: false

  defp allowed?(%Conversation{id: conversation_id}, base_role, actor_uri, action, options)
       when is_integer(conversation_id) and is_binary(actor_uri) and is_atom(action) and
              is_map(options) do
    permissions = effective_permissions(conversation_id, base_role, actor_uri)

    case action do
      :participate ->
        true

      action when action in [:write, :send_messages] ->
        MapSet.member?(permissions, "send_messages")

      :invite ->
        MapSet.member?(permissions, "invite_members")

      action when action in [:ban, :moderation_action] ->
        MapSet.member?(permissions, "manage_moderation")

      action when action in [:role_upsert, :role_assignment] ->
        MapSet.member?(permissions, "manage_roles")

      :permission_overwrite ->
        MapSet.member?(permissions, "manage_permissions")

      :thread_upsert ->
        MapSet.member?(permissions, "manage_moderation") or owner_matches?(options, actor_uri)

      :thread_archive ->
        MapSet.member?(permissions, "manage_moderation") or owner_matches?(options, actor_uri)

      _ ->
        false
    end
  end

  defp allowed?(_conversation, _base_role, _actor_uri, _action, _options), do: false

  defp effective_permissions(conversation_id, base_role, actor_uri)
       when is_integer(conversation_id) and is_binary(actor_uri) do
    acl_state = load_acl_state(conversation_id)
    assigned_role_ids = assigned_role_ids(actor_uri, acl_state.role_assignments)
    effective_role_ids = effective_role_ids(base_role, assigned_role_ids)

    permissions =
      effective_role_ids
      |> Enum.reduce(MapSet.new(), fn role_id, acc ->
        MapSet.union(acc, role_permissions(role_id, acl_state.role_definitions))
      end)
      |> apply_role_overwrites(effective_role_ids, acl_state.permission_overwrites)

    apply_member_overwrites(permissions, actor_uri, acl_state.permission_overwrites)
  end

  defp effective_permissions(_conversation_id, _base_role, _actor_uri), do: MapSet.new()

  defp load_acl_state(conversation_id) when is_integer(conversation_id) do
    from(event in FederationExtensionEvent,
      where: event.conversation_id == ^conversation_id and event.event_type in ^@acl_event_types,
      select: {event.event_type, event.payload}
    )
    |> Repo.all()
    |> Enum.reduce(
      %{role_definitions: %{}, role_assignments: [], permission_overwrites: []},
      fn
        {@role_upsert_event_type, payload}, acc ->
          case get_in(payload, ["role", "id"]) do
            role_id when is_binary(role_id) ->
              permissions =
                payload
                |> get_in(["role", "permissions"])
                |> normalize_permissions()

              put_in(acc, [:role_definitions, role_id], permissions)

            _ ->
              acc
          end

        {@role_assignment_event_type, payload}, acc ->
          role_id = get_in(payload, ["assignment", "role_id"])
          target_type = get_in(payload, ["assignment", "target", "type"])
          target_id = get_in(payload, ["assignment", "target", "id"])
          state = get_in(payload, ["assignment", "state"])

          if is_binary(role_id) and is_binary(target_type) and is_binary(target_id) and
               is_binary(state) do
            %{
              acc
              | role_assignments: [
                  %{
                    role_id: role_id,
                    target_type: target_type,
                    target_id: target_id,
                    state: state
                  }
                  | acc.role_assignments
                ]
            }
          else
            acc
          end

        {@permission_overwrite_event_type, payload}, acc ->
          target_type = get_in(payload, ["overwrite", "target", "type"])
          target_id = get_in(payload, ["overwrite", "target", "id"])

          if is_binary(target_type) and is_binary(target_id) do
            overwrite = %{
              target_type: target_type,
              target_id: target_id,
              allow: normalize_permissions(get_in(payload, ["overwrite", "allow"])),
              deny: normalize_permissions(get_in(payload, ["overwrite", "deny"]))
            }

            %{acc | permission_overwrites: [overwrite | acc.permission_overwrites]}
          else
            acc
          end

        _, acc ->
          acc
      end
    )
  end

  defp load_acl_state(_conversation_id),
    do: %{role_definitions: %{}, role_assignments: [], permission_overwrites: []}

  defp assigned_role_ids(actor_uri, role_assignments)
       when is_binary(actor_uri) and is_list(role_assignments) do
    role_assignments
    |> Enum.filter(fn assignment ->
      assignment.state == "assigned" and assignment.target_type in ["member", "user"] and
        assignment.target_id == actor_uri
    end)
    |> Enum.map(& &1.role_id)
    |> Enum.uniq()
  end

  defp assigned_role_ids(_actor_uri, _role_assignments), do: []

  defp effective_role_ids(base_role, assigned_role_ids)
       when is_binary(base_role) and is_list(assigned_role_ids) do
    {builtin_ids, custom_ids} = Enum.split_with(assigned_role_ids, &builtin_role?/1)

    effective_builtin_id =
      case builtin_ids do
        [] ->
          Map.get(@base_role_ids, base_role, "builtin:member")

        _ ->
          Enum.max_by(builtin_ids, &role_position/1)
      end

    Enum.uniq([effective_builtin_id | custom_ids])
  end

  defp effective_role_ids(_base_role, assigned_role_ids), do: Enum.uniq(assigned_role_ids)

  defp role_permissions(role_id, role_definitions)
       when is_binary(role_id) and is_map(role_definitions) do
    case Map.fetch(@builtin_roles, role_id) do
      {:ok, %{permissions: permissions}} ->
        permissions

      :error ->
        Map.get(role_definitions, role_id, MapSet.new())
    end
  end

  defp role_permissions(_role_id, _role_definitions), do: MapSet.new()

  defp apply_role_overwrites(permissions, effective_role_ids, permission_overwrites)
       when is_list(effective_role_ids) and is_list(permission_overwrites) do
    {allow, deny} =
      permission_overwrites
      |> Enum.filter(fn overwrite ->
        overwrite.target_type == "role" and overwrite.target_id in effective_role_ids
      end)
      |> Enum.reduce({MapSet.new(), MapSet.new()}, fn overwrite, {allow, deny} ->
        {MapSet.union(allow, overwrite.allow), MapSet.union(deny, overwrite.deny)}
      end)

    permissions
    |> MapSet.difference(deny)
    |> MapSet.union(allow)
  end

  defp apply_role_overwrites(permissions, _effective_role_ids, _permission_overwrites),
    do: permissions

  defp apply_member_overwrites(permissions, actor_uri, permission_overwrites)
       when is_binary(actor_uri) and is_list(permission_overwrites) do
    {allow, deny} =
      permission_overwrites
      |> Enum.filter(fn overwrite ->
        overwrite.target_type in ["member", "user"] and overwrite.target_id == actor_uri
      end)
      |> Enum.reduce({MapSet.new(), MapSet.new()}, fn overwrite, {allow, deny} ->
        {MapSet.union(allow, overwrite.allow), MapSet.union(deny, overwrite.deny)}
      end)

    permissions
    |> MapSet.difference(deny)
    |> MapSet.union(allow)
  end

  defp apply_member_overwrites(permissions, _actor_uri, _permission_overwrites), do: permissions

  defp local_actor_uri(user_id) when is_integer(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user -> Utils.sender_payload(user)["uri"]
      _ -> nil
    end
  end

  defp local_actor_uri(_user_id), do: nil

  defp owner_matches?(options, actor_uri) when is_map(options) and is_binary(actor_uri) do
    options[:owner_actor_uri] == actor_uri or
      options[:thread_owner_actor_uri] == actor_uri or
      options[:owner_remote_actor_id] == options[:remote_actor_id] or
      options[:thread_owner_remote_actor_id] == options[:remote_actor_id]
  end

  defp owner_matches?(_options, _actor_uri), do: false

  defp normalize_permissions(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp normalize_permissions(_values), do: MapSet.new()

  defp builtin_role?(role_id) when is_binary(role_id), do: Map.has_key?(@builtin_roles, role_id)
  defp builtin_role?(_role_id), do: false

  defp role_position(role_id) when is_binary(role_id) do
    role_id
    |> then(&Map.get(@builtin_roles, &1, %{position: 0}))
    |> Map.get(:position, 0)
  end

  defp role_position(_role_id), do: 0
end
