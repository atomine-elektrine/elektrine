defmodule Elektrine.Messaging.Federation.VoiceCalls do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.Calls
  alias Elektrine.Messaging.{ChatConversation, ChatConversationMember, FederationCallSession}
  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Federation.DirectMessageState
  alias Elektrine.Messaging.Federation.Utils
  alias Elektrine.Profiles
  alias Elektrine.PubSubTopics
  alias Elektrine.Repo

  @active_statuses ~w(initiated ringing active)
  @valid_call_types ~w(audio video)

  def start_outbound_session(local_user_id, conversation_id, call_type)
      when is_integer(local_user_id) and is_integer(conversation_id) and is_binary(call_type) do
    with true <- call_type in @valid_call_types or {:error, :invalid_call_type},
         %ChatConversation{} = conversation <- Repo.get(ChatConversation, conversation_id),
         true <- conversation.type == "dm" or {:error, :unsupported_conversation_type},
         remote_handle when is_binary(remote_handle) <-
           DirectMessageState.remote_dm_handle_from_source(conversation.federated_source),
         true <- dm_membership_active?(conversation.id, local_user_id) or {:error, :not_member},
         %User{} = local_user <- Repo.get(User, local_user_id),
         {:ok, remote_recipient} <- DirectMessageState.normalize_remote_dm_handle(remote_handle),
         true <-
           is_nil(local_user_busy_reason(local_user_id)) or {:error, :local_call_already_active},
         false <- active_session_exists?(local_user_id, conversation_id) do
      origin_domain = Utils.preferred_dm_origin_domain_for_user(local_user)

      attrs = %{
        conversation_id: conversation.id,
        local_user_id: local_user.id,
        federated_call_id: federated_call_id(origin_domain),
        origin_domain: origin_domain,
        remote_domain: remote_recipient.domain,
        remote_handle: remote_recipient.handle,
        remote_actor: DirectMessageState.dm_actor_payload(remote_recipient),
        call_type: call_type,
        direction: "outbound",
        status: "initiated",
        metadata: %{}
      }

      %FederationCallSession{}
      |> FederationCallSession.changeset(attrs)
      |> Repo.insert()
      |> preload_session()
    else
      {:error, _reason} = error -> error
      nil -> {:error, :not_found}
      false -> {:error, :remote_call_already_active}
      true -> {:error, :remote_call_already_active}
      _ -> {:error, :invalid_remote_call}
    end
  end

  def get_session(session_id) when is_integer(session_id) do
    FederationCallSession
    |> Repo.get(session_id)
    |> maybe_preload_session()
  end

  def get_session_for_local_user(session_id, local_user_id)
      when is_integer(session_id) and is_integer(local_user_id) do
    from(s in FederationCallSession,
      where: s.id == ^session_id and s.local_user_id == ^local_user_id
    )
    |> Repo.one()
    |> maybe_preload_session()
  end

  def get_active_session_for_local_user(local_user_id) when is_integer(local_user_id) do
    from(s in FederationCallSession,
      where: s.local_user_id == ^local_user_id and s.status in ^@active_statuses,
      order_by: [desc: s.updated_at],
      limit: 1
    )
    |> Repo.one()
    |> maybe_preload_session()
  end

  def local_user_busy_reason(local_user_id) when is_integer(local_user_id) do
    cond do
      match?(%{}, Calls.get_active_call(local_user_id)) ->
        :local_call_active

      match?(%{}, get_active_session_for_local_user(local_user_id)) ->
        :federated_call_active

      true ->
        nil
    end
  end

  def accept_session(session_id, local_user_id)
      when is_integer(session_id) and is_integer(local_user_id) do
    with %FederationCallSession{} = session <-
           get_session_for_local_user(session_id, local_user_id),
         true <- session.status in ["initiated", "ringing"] do
      update_session(session, %{
        status: "active",
        started_at_remote: DateTime.utc_now() |> DateTime.truncate(:second)
      })
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_transition}
    end
  end

  def reject_session(session_id, local_user_id, reason \\ nil)
      when is_integer(session_id) and is_integer(local_user_id) do
    with %FederationCallSession{} = session <-
           get_session_for_local_user(session_id, local_user_id),
         true <- session.status in ["initiated", "ringing"] do
      update_session(session, %{
        status: "rejected",
        ended_at_remote: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: put_optional_reason(session.metadata || %{}, reason)
      })
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_transition}
    end
  end

  def end_session(session_id, local_user_id, reason \\ "ended")
      when is_integer(session_id) and is_integer(local_user_id) do
    with %FederationCallSession{} = session <-
           get_session_for_local_user(session_id, local_user_id),
         true <- session.status in @active_statuses do
      update_session(session, %{
        status: "ended",
        ended_at_remote: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: put_optional_reason(session.metadata || %{}, reason)
      })
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_transition}
    end
  end

  def fail_session(session_id, local_user_id, reason \\ "failed")
      when is_integer(session_id) and is_integer(local_user_id) do
    with %FederationCallSession{} = session <-
           get_session_for_local_user(session_id, local_user_id),
         true <- session.status in @active_statuses do
      update_session(session, %{
        status: "failed",
        ended_at_remote: DateTime.utc_now() |> DateTime.truncate(:second),
        metadata: put_optional_reason(session.metadata || %{}, reason)
      })
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_transition}
    end
  end

  def ensure_inbound_session(local_user, conversation, remote_sender, call_payload, remote_domain)
      when is_map(remote_sender) and is_map(call_payload) and is_binary(remote_domain) do
    federated_call_id = normalize_optional_string(call_payload["id"])
    call_type = normalize_optional_string(call_payload["call_type"])
    initiated_at = parse_datetime(call_payload["initiated_at"])
    metadata = Map.get(call_payload, "metadata") || %{}

    with %User{} = local_user <- local_user,
         %ChatConversation{} = conversation <- conversation,
         true <- is_binary(federated_call_id),
         true <- call_type in @valid_call_types do
      existing_session =
        Repo.get_by(FederationCallSession,
          local_user_id: local_user.id,
          federated_call_id: federated_call_id
        )

      if is_nil(existing_session) and local_user_busy_reason(local_user.id) do
        {:error, :busy}
      else
        attrs = %{
          conversation_id: conversation.id,
          local_user_id: local_user.id,
          federated_call_id: federated_call_id,
          origin_domain: String.downcase(remote_domain),
          remote_domain: String.downcase(remote_domain),
          remote_handle: Map.get(remote_sender, :handle) || Map.get(remote_sender, "handle"),
          remote_actor: DirectMessageState.dm_actor_payload(remote_sender),
          call_type: call_type,
          direction: "inbound",
          status: "ringing",
          started_at_remote: initiated_at,
          metadata: metadata
        }

        session =
          case existing_session do
            %FederationCallSession{} = existing ->
              {:ok, updated} =
                existing
                |> FederationCallSession.changeset(attrs)
                |> Repo.update()

              updated

            nil ->
              {:ok, inserted} =
                %FederationCallSession{}
                |> FederationCallSession.changeset(attrs)
                |> Repo.insert()

              inserted
          end
          |> maybe_preload_session()

        broadcast_incoming_call(session)
        {:ok, session}
      end
    else
      {:error, :busy} ->
        {:error, :busy}

      _ ->
        {:error, :invalid_event_payload}
    end
  end

  def reject_inbound_invite(
        local_user,
        conversation,
        remote_sender,
        call_payload,
        remote_domain,
        reason
      )
      when is_map(remote_sender) and is_map(call_payload) and is_binary(remote_domain) do
    with %User{} = local_user <- local_user,
         %ChatConversation{} = conversation <- conversation,
         call_id when is_binary(call_id) <- normalize_optional_string(call_payload["id"]),
         call_type when call_type in @valid_call_types <-
           normalize_optional_string(call_payload["call_type"]) do
      session =
        case Repo.get_by(FederationCallSession,
               local_user_id: local_user.id,
               federated_call_id: call_id
             ) do
          %FederationCallSession{} = existing ->
            {:ok, updated} =
              existing
              |> FederationCallSession.changeset(%{
                status: "rejected",
                ended_at_remote: DateTime.utc_now() |> DateTime.truncate(:second),
                metadata: put_optional_reason(existing.metadata || %{}, reason)
              })
              |> Repo.update()

            updated

          nil ->
            {:ok, inserted} =
              %FederationCallSession{}
              |> FederationCallSession.changeset(%{
                conversation_id: conversation.id,
                local_user_id: local_user.id,
                federated_call_id: call_id,
                origin_domain: String.downcase(remote_domain),
                remote_domain: String.downcase(remote_domain),
                remote_handle:
                  Map.get(remote_sender, :handle) || Map.get(remote_sender, "handle"),
                remote_actor: DirectMessageState.dm_actor_payload(remote_sender),
                call_type: call_type,
                direction: "inbound",
                status: "rejected",
                metadata: put_optional_reason(%{}, reason),
                ended_at_remote: DateTime.utc_now() |> DateTime.truncate(:second)
              })
              |> Repo.insert()

            inserted
        end
        |> maybe_preload_session()

      :ok = Federation.publish_dm_call_reject(session.id)
      {:ok, session}
    else
      _ -> {:error, :invalid_event_payload}
    end
  end

  def apply_remote_accept(dm_payload, call_id, _actor_payload, accepted_at, remote_domain)
      when is_map(dm_payload) and is_binary(call_id) and is_binary(remote_domain) do
    with {:ok, local_user} <- resolve_local_dm_participant(dm_payload),
         %FederationCallSession{} = session <-
           Repo.get_by(FederationCallSession,
             local_user_id: local_user.id,
             federated_call_id: call_id
           ),
         true <- session.remote_domain == String.downcase(remote_domain),
         {:ok, _updated} <-
           update_session(session, %{
             status: "active",
             started_at_remote: parse_datetime(accepted_at) || DateTime.utc_now()
           }) do
      broadcast_peer_ready(session)
      :ok
    else
      nil -> {:error, :not_found}
      false -> {:error, :origin_domain_mismatch}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  def apply_remote_reject(dm_payload, call_id, _actor_payload, rejected_at, reason, remote_domain)
      when is_map(dm_payload) and is_binary(call_id) and is_binary(remote_domain) do
    with {:ok, local_user} <- resolve_local_dm_participant(dm_payload),
         %FederationCallSession{} = session <-
           Repo.get_by(FederationCallSession,
             local_user_id: local_user.id,
             federated_call_id: call_id
           ),
         true <- session.remote_domain == String.downcase(remote_domain),
         {:ok, updated} <-
           update_session(session, %{
             status: "rejected",
             ended_at_remote: parse_datetime(rejected_at) || DateTime.utc_now(),
             metadata: put_optional_reason(session.metadata || %{}, reason)
           }) do
      broadcast_terminal_event(updated, :call_rejected)
      :ok
    else
      nil -> {:error, :not_found}
      false -> {:error, :origin_domain_mismatch}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  def apply_remote_end(dm_payload, call_id, _actor_payload, ended_at, reason, remote_domain)
      when is_map(dm_payload) and is_binary(call_id) and is_binary(remote_domain) do
    with {:ok, local_user} <- resolve_local_dm_participant(dm_payload),
         %FederationCallSession{} = session <-
           Repo.get_by(FederationCallSession,
             local_user_id: local_user.id,
             federated_call_id: call_id
           ),
         true <- session.remote_domain == String.downcase(remote_domain),
         {:ok, updated} <-
           update_session(session, %{
             status: "ended",
             ended_at_remote: parse_datetime(ended_at) || DateTime.utc_now(),
             metadata: put_optional_reason(session.metadata || %{}, reason)
           }) do
      broadcast_terminal_event(updated, :call_ended)
      :ok
    else
      nil -> {:error, :not_found}
      false -> {:error, :origin_domain_mismatch}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_event_payload}
    end
  end

  def apply_remote_signal(dm_payload, call_id, actor_payload, signal, remote_domain)
      when is_map(dm_payload) and is_binary(call_id) and is_map(signal) and
             is_binary(remote_domain) do
    with {:ok, local_user} <- resolve_local_dm_participant(dm_payload),
         %FederationCallSession{} = session <-
           Repo.get_by(FederationCallSession,
             local_user_id: local_user.id,
             federated_call_id: call_id
           ),
         true <- session.remote_domain == String.downcase(remote_domain),
         signal_kind when is_binary(signal_kind) <- signal["kind"] do
      PubSubTopics.broadcast(
        PubSubTopics.call(session.id),
        :federated_call_signal,
        %{
          kind: signal_kind,
          payload: signal["payload"] || %{},
          actor: actor_to_ui_user(actor_payload)
        }
      )

      :ok
    else
      nil -> {:error, :not_found}
      false -> {:error, :origin_domain_mismatch}
      _ -> {:error, :invalid_event_payload}
    end
  end

  def mark_session_ringing(session_id, local_user_id)
      when is_integer(session_id) and is_integer(local_user_id) do
    with %FederationCallSession{} = session <-
           get_session_for_local_user(session_id, local_user_id),
         true <- session.status == "initiated" do
      update_session(session, %{status: "ringing"})
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_transition}
    end
  end

  def ui_call(%FederationCallSession{} = session) do
    session = maybe_preload_session(session)
    local_user = session.local_user
    remote_user = actor_to_ui_user(session.remote_actor)

    caller_is_local? = local_origin_domain?(session.origin_domain, local_user)

    if caller_is_local? do
      %{
        id: session.id,
        source: :federated,
        federated_call_id: session.federated_call_id,
        conversation_id: session.conversation_id,
        call_type: session.call_type,
        status: session.status,
        caller_id: session.local_user_id,
        callee_id: nil,
        caller: local_user,
        callee: remote_user
      }
    else
      %{
        id: session.id,
        source: :federated,
        federated_call_id: session.federated_call_id,
        conversation_id: session.conversation_id,
        call_type: session.call_type,
        status: session.status,
        caller_id: nil,
        callee_id: session.local_user_id,
        caller: remote_user,
        callee: local_user
      }
    end
  end

  defp broadcast_incoming_call(%FederationCallSession{} = session) do
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{session.local_user_id}",
      {:incoming_call, ui_call(session)}
    )
  end

  defp broadcast_terminal_event(%FederationCallSession{} = session, event) do
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      "user:#{session.local_user_id}",
      {event, ui_call(session)}
    )
  end

  defp broadcast_peer_ready(%FederationCallSession{} = session) do
    PubSubTopics.broadcast(PubSubTopics.call(session.id), :federated_peer_ready, %{
      session_id: session.id
    })
  end

  defp update_session(%FederationCallSession{} = session, attrs) do
    session
    |> FederationCallSession.changeset(attrs)
    |> Repo.update()
    |> preload_session()
  end

  defp preload_session({:ok, %FederationCallSession{} = session}) do
    {:ok, maybe_preload_session(session)}
  end

  defp preload_session(other), do: other

  defp maybe_preload_session(%FederationCallSession{} = session) do
    Repo.preload(session, [:conversation, :local_user])
  end

  defp maybe_preload_session(other), do: other

  def resolve_local_dm_participant(%{"sender" => sender, "recipient" => recipient}) do
    case local_actor_payload(sender) || local_actor_payload(recipient) do
      %User{} = user -> {:ok, user}
      _ -> {:error, :user_not_found}
    end
  end

  def resolve_local_dm_participant(_payload), do: {:error, :invalid_event_payload}

  defp local_actor_payload(actor) when is_map(actor) do
    actor_domain = normalize_optional_string(actor["domain"] || actor[:domain])
    username = normalize_optional_string(actor["username"] || actor[:username])
    normalized_actor_domain = if is_binary(actor_domain), do: String.downcase(actor_domain)

    cond do
      normalized_actor_domain == String.downcase(Federation.local_domain()) and
          is_binary(username) ->
        Accounts.get_user_by_username(username)

      is_binary(normalized_actor_domain) and is_binary(username) ->
        case Profiles.get_verified_custom_domain(normalized_actor_domain) do
          %{user: %{username: ^username} = user} -> user
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp local_actor_payload(_actor), do: nil

  defp actor_to_ui_user(actor) when is_map(actor) do
    %{
      username:
        Map.get(actor, "display_name") || Map.get(actor, :display_name) ||
          Map.get(actor, "username") || Map.get(actor, :username) || "remote",
      display_name:
        Map.get(actor, "display_name") || Map.get(actor, :display_name) ||
          Map.get(actor, "username") || Map.get(actor, :username) || "remote",
      avatar_url: Map.get(actor, "avatar_url") || Map.get(actor, :avatar_url),
      handle: Map.get(actor, "handle") || Map.get(actor, :handle),
      remote_handle: Map.get(actor, "handle") || Map.get(actor, :handle),
      domain: Map.get(actor, "domain") || Map.get(actor, :domain),
      origin_domain: Map.get(actor, "domain") || Map.get(actor, :domain)
    }
  end

  defp actor_to_ui_user(_actor), do: %{username: "remote", display_name: "remote"}

  defp dm_membership_active?(conversation_id, user_id) do
    from(cm in ChatConversationMember,
      where:
        cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and is_nil(cm.left_at),
      select: count(cm.id)
    )
    |> Repo.one() > 0
  end

  defp active_session_exists?(local_user_id, conversation_id) do
    from(s in FederationCallSession,
      where:
        s.local_user_id == ^local_user_id and s.conversation_id == ^conversation_id and
          s.status in ^@active_statuses,
      select: count(s.id)
    )
    |> Repo.one() > 0
  end

  defp federated_call_id(local_domain) when is_binary(local_domain) do
    "https://#{local_domain}/_arblarg/calls/#{Ecto.UUID.generate()}"
  end

  defp local_origin_domain?(origin_domain, %User{} = local_user) when is_binary(origin_domain) do
    normalized_origin = String.downcase(origin_domain)

    normalized_origin == String.downcase(Federation.local_domain()) or
      normalized_origin == String.downcase(Utils.preferred_dm_origin_domain_for_user(local_user))
  end

  defp local_origin_domain?(_, _), do: false

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_optional_string(value) when is_binary(value),
    do: Elektrine.Strings.present(value)

  defp normalize_optional_string(_value), do: nil

  defp put_optional_reason(metadata, nil), do: metadata
  defp put_optional_reason(metadata, ""), do: metadata
  defp put_optional_reason(metadata, reason), do: Map.put(metadata, "reason", reason)
end
