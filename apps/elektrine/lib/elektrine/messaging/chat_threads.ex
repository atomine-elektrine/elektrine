defmodule Elektrine.Messaging.ChatThreads do
  @moduledoc """
  Context for chat threads.

  Threads are focused side-conversations attached to channels. A thread can be
  spawned from an existing channel message (the root message stays visible in
  the main timeline) or created standalone. Messages sent into a thread carry
  `chat_messages.thread_id` and are excluded from the channel's main timeline.

  Authorization mirrors the pins feature: server staff (owner/admin/moderator)
  always qualify; other members are resolved through `RoomACL` (`create_threads`
  for creation, `manage_threads` for archiving, with a carve-out for the
  thread's creator).

  Federation: thread lifecycle (create/archive/unarchive) is published as
  `thread.upsert` / `thread.archive` extension events for channels. Thread
  messages federate as regular `message.create` events carrying an optional
  `message.thread_id` reference (spec section 7.6); receivers that do not
  track threads fall back to showing them in the channel timeline.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Elektrine.Messaging.{
    ArblargSDK,
    ChatConversation,
    ChatMessage,
    ChatThread,
    Federation,
    FederationExtensionEvent,
    RoomACL,
    ServerMember
  }

  alias Elektrine.Messaging.Federation.Utils, as: FederationUtils
  alias Elektrine.PubSubTopics
  alias Elektrine.Repo

  # Built-in server roles that always qualify for thread management
  # (mirrors the `create_server_channel` / pins authorization carve-out).
  @staff_roles ["owner", "admin", "moderator"]

  @default_title "New thread"

  ## Fetching

  @doc """
  Gets a thread by id with creator and root message preloaded.
  """
  def get_thread(thread_id) do
    ChatThread
    |> Repo.get(thread_id)
    |> preload_thread()
  end

  @doc """
  Lists a conversation's threads, most recently active first.

  `status` is `:active` (default), `:archived`, or `:all`.
  """
  def list_threads(conversation_id, status \\ :active) do
    base =
      from(thread in ChatThread,
        where: thread.conversation_id == ^conversation_id,
        order_by: [
          desc: coalesce(thread.last_activity_at, thread.inserted_at),
          desc: thread.id
        ],
        preload: [:creator, root_message: [:sender]]
      )

    case status do
      :active -> from(thread in base, where: is_nil(thread.archived_at))
      :archived -> from(thread in base, where: not is_nil(thread.archived_at))
      :all -> base
    end
    |> Repo.all()
    |> Enum.map(&decrypt_root_message/1)
  end

  @doc """
  Lists the messages inside a thread, oldest first.
  """
  def list_thread_messages(thread_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    from(m in ChatMessage,
      where: m.thread_id == ^thread_id and is_nil(m.deleted_at),
      order_by: [asc: m.inserted_at, asc: m.id],
      limit: ^limit,
      preload: [:sender, :link_preview, reply_to: [:sender], reactions: [:user, :remote_actor]]
    )
    |> Repo.all()
    |> ChatMessage.decrypt_messages()
  end

  ## Creation

  @doc """
  Creates a thread from an existing channel message. The message becomes the
  thread's root and stays in the main timeline. Requires the `create_threads`
  permission (server staff always qualify).
  """
  def create_thread_from_message(message_id, user_id, attrs \\ %{}) do
    with %ChatMessage{deleted_at: nil, thread_id: nil} = message <- fetch_message(message_id),
         %ChatConversation{} = conversation <- get_channel(message.conversation_id),
         :ok <- authorize_create(conversation, user_id),
         nil <- Repo.get_by(ChatThread, root_message_id: message.id) do
      message = ChatMessage.decrypt_content(message)

      insert_thread(conversation, user_id, %{
        root_message_id: message.id,
        title: normalized_title(attrs) || title_from_content(message.content)
      })
    else
      nil -> {:error, :not_found}
      %ChatThread{} -> {:error, :thread_exists}
      %ChatMessage{} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a standalone thread in a channel (no root message). Requires the
  `create_threads` permission (server staff always qualify).
  """
  def create_thread(conversation_id, user_id, attrs) do
    with %ChatConversation{} = conversation <- get_channel(conversation_id),
         :ok <- authorize_create(conversation, user_id) do
      insert_thread(conversation, user_id, %{
        title: normalized_title(attrs) || @default_title
      })
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Archiving

  @doc """
  Archives a thread. Allowed for the thread's creator or holders of the
  `manage_threads` permission (server staff always qualify).
  """
  def archive_thread(thread_id, user_id) do
    with %ChatThread{archived_at: nil} = thread <- Repo.get(ChatThread, thread_id),
         :ok <- authorize_manage(thread, user_id) do
      thread
      |> ChatThread.changeset(%{archived_at: Elektrine.Time.utc_now()})
      |> Repo.update()
      |> case do
        {:ok, thread} ->
          thread = preload_thread(thread)
          broadcast_thread_event(:thread_archived, thread)
          publish_thread_archived(thread, user_id)
          {:ok, thread}

        error ->
          error
      end
    else
      nil -> {:error, :not_found}
      %ChatThread{} -> {:error, :already_archived}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Unarchives a thread. Same authorization as `archive_thread/2`.
  """
  def unarchive_thread(thread_id, user_id) do
    with %ChatThread{archived_at: %DateTime{}} = thread <- Repo.get(ChatThread, thread_id),
         :ok <- authorize_manage(thread, user_id) do
      thread
      |> ChatThread.changeset(%{archived_at: nil})
      |> Repo.update()
      |> case do
        {:ok, thread} ->
          thread = preload_thread(thread)
          broadcast_thread_event(:thread_updated, thread)
          publish_thread_upsert(thread, user_id)
          {:ok, thread}

        error ->
          error
      end
    else
      nil -> {:error, :not_found}
      %ChatThread{} -> {:error, :not_archived}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Thread messages

  @doc """
  Sends a text message into a thread. Reuses the regular chat send path (write
  permission on the parent conversation) and bumps the thread's activity
  counters. The message federates with a `thread_id` reference when the
  parent channel federates.
  """
  def create_thread_message(thread_id, sender_id, content, opts \\ []) do
    case Repo.get(ChatThread, thread_id) do
      nil ->
        {:error, :not_found}

      %ChatThread{archived_at: archived_at} when not is_nil(archived_at) ->
        {:error, :thread_archived}

      %ChatThread{} = thread ->
        Elektrine.Messaging.ChatMessages.create_text_message(
          thread.conversation_id,
          sender_id,
          content,
          Keyword.put(opts, :thread_id, thread.id)
        )
    end
  end

  @doc """
  Bumps a thread's `message_count` / `last_activity_at` for a newly created
  thread message and broadcasts the updated thread. Called from the chat
  message creation path.
  """
  def record_message_activity(%ChatMessage{thread_id: thread_id} = message)
      when is_integer(thread_id) do
    last_activity =
      case message.inserted_at do
        %NaiveDateTime{} = naive -> DateTime.from_naive!(naive, "Etc/UTC")
        %DateTime{} = datetime -> datetime
        _ -> DateTime.utc_now()
      end
      |> DateTime.truncate(:second)

    from(thread in ChatThread, where: thread.id == ^thread_id)
    |> Repo.update_all(
      inc: [message_count: 1],
      set: [last_activity_at: last_activity]
    )

    case get_thread(thread_id) do
      %ChatThread{} = thread ->
        broadcast_thread_event(:thread_updated, thread)
        :ok

      nil ->
        :ok
    end
  end

  def record_message_activity(_message), do: :ok

  ## Federation projection (inbound)

  @doc """
  Projects an accepted `thread.upsert` / `thread.archive` extension event into
  a local `chat_threads` row, keyed by `federation_id` + `origin_domain`.

  The passed projection row is the current winning state from the
  last-write-wins extension event storage, so replaying a stale event simply
  reapplies the winning state. Never raises; returns `:ok` even when the
  payload cannot be projected (the extension event state is still stored).
  """
  def apply_remote_thread_projection(
        %ChatConversation{} = conversation,
        %FederationExtensionEvent{} = projection
      ) do
    upsert_type = ArblargSDK.canonical_event_type("thread.upsert")
    archive_type = ArblargSDK.canonical_event_type("thread.archive")

    result =
      cond do
        projection.event_type == upsert_type ->
          project_remote_thread_upsert(conversation, projection)

        projection.event_type == archive_type ->
          project_remote_thread_archive(conversation, projection)

        true ->
          :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "chat_threads: failed to project remote thread event #{projection.event_type} " <>
            "for conversation #{conversation.id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  def apply_remote_thread_projection(_conversation, _projection), do: :ok

  ## Outbound federation payloads

  @doc """
  Builds the `thread.upsert` extension payload for a local thread. The
  federation builder fills in server/channel/refs and defaults the owner to
  the publishing actor.
  """
  def thread_upsert_payload(%ChatThread{} = thread, %ChatConversation{} = conversation) do
    %{
      "thread" =>
        %{
          "id" => thread_federation_ref(thread),
          "channel_id" => channel_federation_ref(conversation),
          "name" => thread.title,
          "state" => if(ChatThread.archived?(thread), do: "archived", else: "active"),
          "message_count" => thread.message_count
        }
        |> maybe_put_owner(thread)
    }
  end

  @doc """
  Builds the `thread.archive` extension payload for a local thread. The
  federation builder fills in server/channel/refs and the acting user.
  """
  def thread_archive_payload(%ChatThread{} = thread) do
    archived_at = thread.archived_at || Elektrine.Time.utc_now()

    %{
      "thread_id" => thread_federation_ref(thread),
      "archived_at" => DateTime.to_iso8601(archived_at)
    }
  end

  @doc """
  Returns the federation identifier used for this thread in extension events:
  the origin-assigned id for remote threads, a local URI otherwise.
  """
  def thread_federation_ref(%ChatThread{federation_id: federation_id})
      when is_binary(federation_id),
      do: federation_id

  def thread_federation_ref(%ChatThread{id: id}),
    do: FederationUtils.thread_federation_id(id)

  @doc """
  Returns the federation thread ref carried on outbound `message.create`
  payloads for a thread message, or nil for main-timeline messages.
  """
  def message_thread_ref(%{thread_id: thread_id}) when is_integer(thread_id) do
    case Repo.get(ChatThread, thread_id) do
      %ChatThread{} = thread -> thread_federation_ref(thread)
      nil -> nil
    end
  end

  def message_thread_ref(_message), do: nil

  @doc """
  Resolves the local thread referenced by an inbound `message.thread_id`
  within `conversation_id`. Remote-origin threads match on their stored
  `federation_id`; local threads match their minted local ref. Returns nil
  for unknown refs so callers fall back to the main timeline (per spec
  section 7.6).
  """
  def resolve_thread_for_message_ref(conversation_id, ref)
      when is_integer(conversation_id) and is_binary(ref) do
    remote =
      from(thread in ChatThread,
        where: thread.conversation_id == ^conversation_id and thread.federation_id == ^ref,
        limit: 1
      )
      |> Repo.one()

    remote || resolve_local_thread_ref(conversation_id, ref)
  end

  def resolve_thread_for_message_ref(_conversation_id, _ref), do: nil

  defp resolve_local_thread_ref(conversation_id, ref) do
    case String.split(ref, "/_arblarg/threads/") do
      [_base, id_string] ->
        with {thread_id, ""} <- Integer.parse(id_string),
             # Re-minting the ref verifies scheme + domain, so foreign refs
             # cannot bind to arbitrary local thread ids.
             true <- FederationUtils.thread_federation_id(thread_id) == ref,
             %ChatThread{conversation_id: ^conversation_id, federation_id: nil} = thread <-
               Repo.get(ChatThread, thread_id) do
          thread
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp channel_federation_ref(%ChatConversation{} = conversation) do
    conversation.federated_source || FederationUtils.channel_federation_id(conversation.id)
  end

  # Private helpers

  defp insert_thread(%ChatConversation{} = conversation, user_id, attrs) do
    now = Elektrine.Time.utc_now()

    %ChatThread{}
    |> ChatThread.changeset(
      Map.merge(attrs, %{
        conversation_id: conversation.id,
        creator_id: user_id,
        last_activity_at: now
      })
    )
    |> Repo.insert()
    |> case do
      {:ok, thread} ->
        thread = preload_thread(thread)
        broadcast_thread_event(:thread_created, thread)
        publish_thread_upsert(thread, user_id, conversation)
        {:ok, thread}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :root_message_id) do
          {:error, :thread_exists}
        else
          {:error, changeset}
        end
    end
  end

  defp project_remote_thread_upsert(conversation, projection) do
    with %{} = thread_payload <- projection.payload["thread"],
         federation_id when is_binary(federation_id) <- thread_payload["id"],
         title when is_binary(title) <- thread_payload["name"] do
      state = thread_payload["state"]
      occurred_at = projection.occurred_at || DateTime.utc_now()

      existing =
        Repo.get_by(ChatThread,
          federation_id: federation_id,
          origin_domain: projection.origin_domain
        )

      attrs =
        %{
          conversation_id: conversation.id,
          title: title,
          federation_id: federation_id,
          origin_domain: projection.origin_domain,
          archived_at: remote_archived_at(state, existing, occurred_at),
          last_activity_at: occurred_at
        }
        |> maybe_put_remote_message_count(thread_payload["message_count"])

      case existing do
        nil ->
          %ChatThread{}
          |> ChatThread.changeset(attrs)
          |> Repo.insert()
          |> broadcast_remote_result(:thread_created)

        %ChatThread{} = thread ->
          thread
          |> ChatThread.changeset(attrs)
          |> Repo.update()
          |> broadcast_remote_result(:thread_updated)
      end
    else
      _ -> {:error, :invalid_thread_payload}
    end
  end

  defp project_remote_thread_archive(conversation, projection) do
    with federation_id when is_binary(federation_id) <- projection.payload["thread_id"],
         %ChatThread{} = thread <-
           Repo.get_by(ChatThread,
             federation_id: federation_id,
             origin_domain: projection.origin_domain
           ),
         true <- thread.conversation_id == conversation.id do
      thread
      |> ChatThread.changeset(%{archived_at: projection.occurred_at || DateTime.utc_now()})
      |> Repo.update()
      |> broadcast_remote_result(:thread_archived)
    else
      # An archive for a thread we never projected is a no-op locally; the
      # extension event state is still retained for replay.
      nil -> :ok
      false -> :ok
      _ -> {:error, :invalid_thread_payload}
    end
  end

  defp remote_archived_at("archived", %ChatThread{archived_at: %DateTime{} = existing}, _at),
    do: existing

  defp remote_archived_at("archived", _existing, occurred_at), do: occurred_at

  defp remote_archived_at("locked", existing, occurred_at),
    do: remote_archived_at("archived", existing, occurred_at)

  defp remote_archived_at(_state, _existing, _occurred_at), do: nil

  defp maybe_put_remote_message_count(attrs, count) when is_integer(count) and count >= 0,
    do: Map.put(attrs, :message_count, count)

  defp maybe_put_remote_message_count(attrs, _count), do: attrs

  defp broadcast_remote_result({:ok, thread}, event) do
    broadcast_thread_event(event, preload_thread(thread))
    :ok
  end

  defp broadcast_remote_result({:error, reason}, _event), do: {:error, reason}

  ## Authorization

  defp get_channel(conversation_id) do
    case Repo.get(ChatConversation, conversation_id) do
      %ChatConversation{type: "channel"} = conversation -> conversation
      %ChatConversation{} -> {:error, :unsupported_conversation_type}
      nil -> nil
    end
  end

  defp authorize_create(%ChatConversation{} = conversation, user_id) do
    if server_staff?(conversation.server_id, user_id) do
      :ok
    else
      RoomACL.authorize_local_user_action(conversation.id, user_id, :create_threads)
    end
  end

  defp authorize_manage(%ChatThread{} = thread, user_id) do
    server_id =
      case Repo.get(ChatConversation, thread.conversation_id) do
        %ChatConversation{server_id: server_id} -> server_id
        _ -> nil
      end

    cond do
      is_integer(user_id) and thread.creator_id == user_id ->
        :ok

      server_staff?(server_id, user_id) ->
        :ok

      true ->
        RoomACL.authorize_local_user_action(thread.conversation_id, user_id, :manage_threads)
    end
  end

  defp server_staff?(server_id, user_id) when is_integer(server_id) and is_integer(user_id) do
    from(sm in ServerMember,
      where:
        sm.server_id == ^server_id and sm.user_id == ^user_id and is_nil(sm.left_at) and
          sm.role in ^@staff_roles
    )
    |> Repo.exists?()
  end

  defp server_staff?(_server_id, _user_id), do: false

  ## Federation publishing (outbound)

  defp publish_thread_upsert(%ChatThread{} = thread, user_id, conversation \\ nil) do
    conversation = conversation || Repo.get(ChatConversation, thread.conversation_id)

    if match?(%ChatConversation{type: "channel"}, conversation) and is_integer(user_id) do
      _ =
        Federation.publish_extension_event(
          conversation.id,
          user_id,
          "thread.upsert",
          thread_upsert_payload(thread, conversation)
        )
    end

    :ok
  end

  defp publish_thread_archived(%ChatThread{} = thread, user_id) do
    conversation = Repo.get(ChatConversation, thread.conversation_id)

    if match?(%ChatConversation{type: "channel"}, conversation) and is_integer(user_id) do
      _ =
        Federation.publish_extension_event(
          conversation.id,
          user_id,
          "thread.archive",
          thread_archive_payload(thread)
        )
    end

    :ok
  end

  defp maybe_put_owner(thread_payload, %ChatThread{creator: %Elektrine.Accounts.User{} = creator}) do
    Map.put(thread_payload, "owner", FederationUtils.sender_payload(creator))
  end

  defp maybe_put_owner(thread_payload, _thread), do: thread_payload

  ## Misc helpers

  defp fetch_message(message_id) when is_integer(message_id),
    do: Repo.get(ChatMessage, message_id)

  defp fetch_message(message_id) when is_binary(message_id) do
    case Integer.parse(message_id) do
      {id, ""} -> fetch_message(id)
      _ -> nil
    end
  end

  defp fetch_message(_message_id), do: nil

  defp preload_thread(nil), do: nil

  defp preload_thread(%ChatThread{} = thread) do
    thread
    |> Repo.preload([:creator, root_message: [:sender]])
    |> decrypt_root_message()
  end

  defp decrypt_root_message(%ChatThread{root_message: %ChatMessage{} = root} = thread) do
    %{thread | root_message: ChatMessage.decrypt_content(root)}
  end

  defp decrypt_root_message(thread), do: thread

  defp normalized_title(attrs) when is_map(attrs) do
    title = Map.get(attrs, :title) || Map.get(attrs, "title")

    if is_binary(title) and String.trim(title) != "" do
      String.trim(title)
    else
      nil
    end
  end

  defp normalized_title(_attrs), do: nil

  defp title_from_content(content) when is_binary(content) do
    content
    |> String.trim()
    |> String.slice(0, 60)
    |> case do
      "" -> @default_title
      snippet -> snippet
    end
  end

  defp title_from_content(_content), do: @default_title

  defp broadcast_thread_event(event, %ChatThread{} = thread) do
    Phoenix.PubSub.broadcast(
      Elektrine.PubSub,
      PubSubTopics.conversation(thread.conversation_id),
      {event, thread}
    )
  end
end
