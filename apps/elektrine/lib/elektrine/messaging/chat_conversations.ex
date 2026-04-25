defmodule Elektrine.Messaging.ChatConversations do
  @moduledoc "Context for chat conversations backed by chat-specific tables."

  import Ecto.Query, warn: false

  alias Elektrine.Accounts
  alias Elektrine.Accounts.User
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor, as: ActivityPubActor
  alias Elektrine.Messaging.ChatConversation
  alias Elektrine.Messaging.ChatConversationMember
  alias Elektrine.Messaging.ChatMessage
  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Federation.DirectMessageState
  alias Elektrine.Messaging.Federation.State, as: FederationState
  alias Elektrine.Messaging.Federation.Utils, as: FederationUtils
  alias Elektrine.Messaging.FederationInviteState
  alias Elektrine.Messaging.FederationMembershipState
  alias Elektrine.Messaging.RateLimiter
  alias Elektrine.Profiles
  alias Elektrine.Repo

  @doc "Returns chat conversations for a user."
  def list_conversations(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(c in ChatConversation,
        join: cm in ChatConversationMember,
        on: c.id == cm.conversation_id and cm.user_id == ^user_id,
        where: is_nil(cm.left_at),
        order_by: [desc: cm.pinned, desc: c.last_message_at, desc: c.updated_at],
        limit: ^limit,
        preload: [members: [user: [:profile]]]
      )

    conversations = Repo.all(query)
    conversation_ids = Enum.map(conversations, & &1.id)

    latest_messages =
      from(m in ChatMessage,
        where: m.conversation_id in ^conversation_ids and is_nil(m.deleted_at),
        distinct: m.conversation_id,
        order_by: [asc: m.conversation_id, desc: m.inserted_at],
        preload: [sender: [:profile]]
      )
      |> Repo.all()
      |> ChatMessage.decrypt_messages()
      |> Enum.group_by(& &1.conversation_id)

    Enum.map(conversations, fn conversation ->
      %{conversation | messages: Map.get(latest_messages, conversation.id, [])}
    end)
    |> filter_blocked_conversations(user_id)
  end

  def get_conversation!(id, user_id) do
    query =
      from(c in ChatConversation,
        join: cm in ChatConversationMember,
        on: c.id == cm.conversation_id and cm.user_id == ^user_id,
        where: c.id == ^id and is_nil(cm.left_at),
        preload: [creator: [], members: [user: [:profile]]]
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      conversation ->
        {:ok, %{conversation | messages: load_recent_conversation_messages(conversation)}}
    end
  end

  def get_conversation_for_chat!(id, user_id) do
    query =
      from(c in ChatConversation,
        join: cm in ChatConversationMember,
        on: c.id == cm.conversation_id and cm.user_id == ^user_id,
        where: c.id == ^id and is_nil(cm.left_at),
        preload: [creator: [], members: [user: [:profile]]]
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      conversation -> {:ok, %{conversation | messages: []}}
    end
  end

  def get_conversation_by_hash(hash) do
    from(c in ChatConversation, where: c.hash == ^hash, preload: [:creator, members: :user])
    |> Repo.one()
  end

  def get_conversation_for_chat_by_hash!(hash, user_id) do
    query =
      from(c in ChatConversation,
        join: cm in ChatConversationMember,
        on: c.id == cm.conversation_id and cm.user_id == ^user_id,
        where: c.hash == ^hash and is_nil(cm.left_at),
        preload: [creator: [], members: [user: [:profile]]]
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      conversation -> {:ok, %{conversation | messages: []}}
    end
  end

  def create_dm_conversation(user1_id, user2_id) do
    if RateLimiter.can_create_dm?(user1_id) do
      case Elektrine.Privacy.can_send_dm?(user1_id, user2_id) do
        {:error, reason} ->
          {:error, reason}

        {:ok, :allowed} ->
          existing_dm =
            from(c in ChatConversation,
              join: cm1 in ChatConversationMember,
              on: c.id == cm1.conversation_id,
              join: cm2 in ChatConversationMember,
              on: c.id == cm2.conversation_id,
              where:
                c.type == "dm" and cm1.user_id == ^user1_id and is_nil(cm1.left_at) and
                  cm2.user_id == ^user2_id and is_nil(cm2.left_at),
              limit: 1
            )

          case Repo.one(existing_dm) do
            %ChatConversation{} = conversation ->
              {:ok, conversation}

            nil ->
              RateLimiter.record_dm_creation(user1_id)

              Repo.transaction(fn ->
                {:ok, conversation} =
                  %ChatConversation{}
                  |> ChatConversation.dm_changeset(%{creator_id: user1_id})
                  |> Repo.insert()

                {:ok, _} = add_member_to_conversation(conversation.id, user1_id)
                {:ok, _} = add_member_to_conversation(conversation.id, user2_id)
                conversation
              end)
          end
      end
    else
      {:error, :rate_limited}
    end
  end

  def create_remote_dm_conversation(local_user_id, remote_handle, attrs \\ %{}) do
    with :ok <- ensure_dm_creation_allowed(local_user_id),
         {:ok, recipient} <- normalize_remote_dm_handle(remote_handle),
         :ok <- ensure_remote_recipient_domain(local_user_id, recipient),
         %{} <- Federation.outgoing_peer(recipient.domain) do
      remote_source = DirectMessageState.remote_dm_source(recipient.handle)
      display_name = remote_dm_display_name(attrs, recipient)
      avatar_url = remote_dm_avatar_url(attrs)

      existing_remote_dm =
        from(c in ChatConversation,
          join: cm in ChatConversationMember,
          on: c.id == cm.conversation_id,
          where:
            c.type == "dm" and c.federated_source == ^remote_source and
              cm.user_id == ^local_user_id and is_nil(cm.left_at),
          limit: 1
        )

      case Repo.one(existing_remote_dm) do
        %ChatConversation{} = conversation ->
          {:ok, conversation}

        nil ->
          RateLimiter.record_dm_creation(local_user_id)

          Repo.transaction(fn ->
            {:ok, conversation} =
              %ChatConversation{}
              |> ChatConversation.dm_changeset(%{
                creator_id: local_user_id,
                name: display_name,
                avatar_url: avatar_url,
                federated_source: remote_source
              })
              |> Repo.insert()

            {:ok, _} = add_member_to_conversation(conversation.id, local_user_id)
            update_member_count(conversation.id)
            conversation
          end)
      end
    else
      {:redirect_local_dm, remote_user_id} ->
        create_dm_conversation(local_user_id, remote_user_id)

      nil ->
        {:error, :unknown_peer}

      {:error, _} = error ->
        error

      false ->
        {:error, :rate_limited}
    end
  end

  def remote_dm_conversation?(%ChatConversation{type: "dm", federated_source: source})
      when is_binary(source) do
    is_binary(DirectMessageState.remote_dm_handle_from_source(source))
  end

  def remote_dm_conversation?(_), do: false

  def remote_dm_handle(%ChatConversation{} = conversation) do
    if remote_dm_conversation?(conversation),
      do: DirectMessageState.remote_dm_handle_from_source(conversation.federated_source),
      else: nil
  end

  def remote_dm_handle(_), do: nil

  def check_creation_limit(user_id, type) do
    max_channels = 10
    max_groups = 20

    case type do
      "channel" ->
        count =
          from(c in ChatConversation,
            where: c.creator_id == ^user_id and c.type == "channel",
            select: count(c.id)
          )
          |> Repo.one()

        if count < max_channels, do: :ok, else: {:error, :limit_exceeded}

      "group" ->
        count =
          from(c in ChatConversation,
            where: c.creator_id == ^user_id and c.type == "group",
            select: count(c.id)
          )
          |> Repo.one()

        if count < max_groups, do: :ok, else: {:error, :limit_exceeded}

      _ ->
        :ok
    end
  end

  def create_group_conversation(creator_id, attrs, member_ids \\ []) do
    case check_creation_limit(creator_id, "group") do
      :ok ->
        attrs = Map.put(attrs, :creator_id, creator_id)

        Repo.transaction(fn ->
          {:ok, conversation} =
            %ChatConversation{} |> ChatConversation.group_changeset(attrs) |> Repo.insert()

          {:ok, _} = add_member_to_conversation(conversation.id, creator_id, "admin")

          {successful_adds, failed_adds} =
            Enum.reduce(member_ids, {[], []}, fn user_id, {success, failed} ->
              case add_member_to_conversation(conversation.id, user_id, "member", creator_id) do
                {:ok, _} -> {[user_id | success], failed}
                {:error, _reason} -> {success, [user_id | failed]}
              end
            end)

          update_member_count(conversation.id)
          all_member_ids = [creator_id | successful_adds]

          Enum.each(all_member_ids, fn user_id ->
            Phoenix.PubSub.broadcast(
              Elektrine.PubSub,
              "user:#{user_id}",
              {:added_to_conversation, %{conversation_id: conversation.id}}
            )
          end)

          {conversation, length(failed_adds)}
        end)
        |> case do
          {:ok, {conversation, 0}} -> {:ok, conversation}
          {:ok, {conversation, failed_count}} -> {:ok, conversation, failed_count}
          error -> error
        end

      {:error, :limit_exceeded} ->
        {:error, :group_limit_exceeded}
    end
  end

  def create_channel(creator_id, attrs) do
    case check_creation_limit(creator_id, "channel") do
      :ok ->
        attrs = Map.put(attrs, :creator_id, creator_id)

        Repo.transaction(fn ->
          {:ok, conversation} =
            %ChatConversation{} |> ChatConversation.channel_changeset(attrs) |> Repo.insert()

          {:ok, _} = add_member_to_conversation(conversation.id, creator_id, "admin")
          update_member_count(conversation.id)
          conversation
        end)

      {:error, :limit_exceeded} ->
        {:error, :channel_limit_exceeded}
    end
  end

  def update_conversation(conversation, attrs) do
    conversation |> ChatConversation.changeset(attrs) |> Repo.update()
  end

  def delete_conversation(conversation_id) do
    case Repo.get(ChatConversation, conversation_id) do
      nil -> {:error, :not_found}
      conversation -> Repo.delete(conversation)
    end
  end

  def list_public_channels(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(c in ChatConversation,
      where: c.type == "channel" and c.is_public == true and is_nil(c.server_id),
      order_by: [desc: c.member_count, desc: c.last_message_at],
      limit: ^limit,
      preload: [:creator]
    )
    |> Repo.all()
  end

  def list_public_groups(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(c in ChatConversation,
      where: c.type == "group" and c.is_public == true,
      order_by: [desc: c.member_count, desc: c.last_message_at],
      limit: ^limit,
      preload: [:creator]
    )
    |> Repo.all()
  end

  def search_public_conversations(query, current_user_id, limit \\ 10) do
    search_term = "%#{query}%"

    user_conversation_ids =
      from(cm in ChatConversationMember,
        where: cm.user_id == ^current_user_id and is_nil(cm.left_at),
        select: cm.conversation_id
      )
      |> Repo.all()

    from(c in ChatConversation,
      where:
        c.is_public == true and c.type in ["group", "channel"] and is_nil(c.server_id) and
          c.id not in ^user_conversation_ids and
          (ilike(c.name, ^search_term) or ilike(c.description, ^search_term)),
      order_by: [desc: c.member_count, desc: c.last_message_at],
      limit: ^limit,
      preload: [:creator]
    )
    |> Repo.all()
  end

  def add_member_to_conversation(
        conversation_id,
        user_id,
        role \\ "member",
        added_by_user_id \\ nil
      ) do
    if added_by_user_id do
      case Elektrine.Privacy.can_add_to_group?(added_by_user_id, user_id) do
        {:error, reason} ->
          {:error, reason}

        {:ok, :allowed} ->
          do_add_member_to_conversation(conversation_id, user_id, role, added_by_user_id, true)
      end
    else
      do_add_member_to_conversation(conversation_id, user_id, role, nil, true)
    end
  end

  def add_member_to_conversation_without_federation(conversation_id, user_id, role \\ "member") do
    do_add_member_to_conversation(conversation_id, user_id, role, nil, false)
  end

  def remove_member_from_conversation(conversation_id, user_id) do
    member =
      from(cm in ChatConversationMember,
        where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id
      )
      |> Repo.one()

    case member do
      nil ->
        {:error, :not_found}

      member ->
        member
        |> ChatConversationMember.remove_member_changeset()
        |> Repo.update()
        |> case do
          {:ok, updated_member} ->
            update_member_count(conversation_id)

            _ =
              Federation.publish_membership_state(
                conversation_id,
                user_id,
                membership_state_for_departure(updated_member),
                updated_member.role || "member"
              )

            Phoenix.PubSub.broadcast(
              Elektrine.PubSub,
              "conversation:#{conversation_id}",
              {:member_left, %{user_id: user_id, conversation_id: conversation_id}}
            )

            {:ok, updated_member}

          error ->
            error
        end
    end
  end

  def get_conversation_member(conversation_id, user_id) do
    from(cm in ChatConversationMember,
      where:
        cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and is_nil(cm.left_at)
    )
    |> Repo.one()
  end

  def get_conversation_members(conversation_id) do
    from(cm in ChatConversationMember,
      join: u in User,
      on: u.id == cm.user_id,
      where: cm.conversation_id == ^conversation_id and is_nil(cm.left_at),
      select: %{
        user_id: u.id,
        username: u.username,
        handle: u.handle,
        display_name: u.display_name,
        avatar: u.avatar,
        verified: u.verified,
        joined_at: cm.joined_at,
        role: cm.role
      },
      order_by: [desc: cm.role, asc: cm.joined_at]
    )
    |> Repo.all()
  end

  def list_pending_remote_join_requests(conversation_id) when is_integer(conversation_id) do
    case remote_join_review_conversation(conversation_id) do
      {:ok, _conversation} ->
        local_domain = Federation.local_domain()

        from(state in FederationMembershipState,
          where: state.conversation_id == ^conversation_id and state.state == "invited",
          where: state.origin_domain != ^local_domain,
          preload: [:remote_actor],
          order_by: [asc: state.inserted_at]
        )
        |> Repo.all()
        |> Enum.filter(&pending_remote_join_request?/1)
        |> Enum.map(&format_pending_remote_join_request/1)

      {:error, _reason} ->
        []
    end
  end

  def list_pending_remote_join_requests(_conversation_id), do: []

  def approve_remote_join_request(conversation_id, remote_actor_id, reviewer_user_id)
      when is_integer(conversation_id) and is_integer(remote_actor_id) and
             is_integer(reviewer_user_id),
      do:
        review_remote_join_request(conversation_id, remote_actor_id, reviewer_user_id, "accepted")

  def approve_remote_join_request(_, _, _), do: {:error, :not_found}

  def decline_remote_join_request(conversation_id, remote_actor_id, reviewer_user_id)
      when is_integer(conversation_id) and is_integer(remote_actor_id) and
             is_integer(reviewer_user_id),
      do:
        review_remote_join_request(conversation_id, remote_actor_id, reviewer_user_id, "declined")

  def decline_remote_join_request(_, _, _), do: {:error, :not_found}

  def promote_to_admin(conversation_id, user_id, promoter_id) do
    with {:ok, _conversation} <- get_conversation_basic(conversation_id),
         true <- admin?(conversation_id, promoter_id) do
      member =
        from(cm in ChatConversationMember,
          where:
            cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and
              is_nil(cm.left_at)
        )
        |> Repo.one()

      case member do
        nil ->
          {:error, :not_found}

        member ->
          member
          |> ChatConversationMember.changeset(%{role: "admin"})
          |> Repo.update()
          |> case do
            {:ok, updated_member} ->
              _ = Federation.publish_membership_state(conversation_id, user_id, "active", "admin")
              maybe_publish_role_assignment(conversation_id, user_id, "admin", promoter_id)
              {:ok, updated_member}

            error ->
              error
          end
      end
    else
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  def demote_from_admin(conversation_id, user_id, demoter_id) do
    with {:ok, conversation} <- get_conversation_basic(conversation_id),
         true <- admin?(conversation_id, demoter_id),
         false <- conversation.creator_id == user_id do
      member =
        from(cm in ChatConversationMember,
          where:
            cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and
              is_nil(cm.left_at)
        )
        |> Repo.one()

      case member do
        nil ->
          {:error, :not_found}

        member ->
          member
          |> ChatConversationMember.changeset(%{role: "member"})
          |> Repo.update()
          |> case do
            {:ok, updated_member} ->
              _ =
                Federation.publish_membership_state(conversation_id, user_id, "active", "member")

              maybe_publish_role_assignment(conversation_id, user_id, "member", demoter_id)
              {:ok, updated_member}

            error ->
              error
          end
      end
    else
      true -> {:error, :cannot_demote_creator}
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  def update_member_role(conversation_id, user_id, new_role),
    do: update_member_role(conversation_id, user_id, new_role, nil)

  def update_member_role(conversation_id, user_id, new_role, actor_user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :member_not_found}

      member ->
        member
        |> ChatConversationMember.changeset(%{role: new_role})
        |> Repo.update()
        |> case do
          {:ok, updated_member} ->
            _ = Federation.publish_membership_state(conversation_id, user_id, "active", new_role)
            maybe_publish_role_assignment(conversation_id, user_id, new_role, actor_user_id)
            {:ok, updated_member}

          error ->
            error
        end
    end
  end

  def join_conversation(conversation_id, user_id) do
    case get_conversation_basic(conversation_id) do
      {:error, _} = error ->
        error

      {:ok, conversation} ->
        cond do
          remote_mirror_channel_join?(conversation) ->
            request_mirrored_channel_join(conversation, user_id)

          conversation.type == "channel" and not is_nil(conversation.server_id) ->
            {:error, :must_join_server}

          conversation.type not in ["channel", "group"] ->
            {:error, :not_joinable}

          conversation.is_public != true ->
            {:error, :not_public_channel}

          true ->
            existing_member =
              from(cm in ChatConversationMember,
                where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id
              )
              |> Repo.one()

            case existing_member do
              nil ->
                role = if conversation.type == "channel", do: "readonly", else: "member"
                add_member_to_conversation(conversation_id, user_id, role)

              %ChatConversationMember{left_at: nil} ->
                {:error, :already_member}

              %ChatConversationMember{} = member ->
                result =
                  member
                  |> ChatConversationMember.changeset(%{
                    left_at: nil,
                    joined_at: DateTime.utc_now()
                  })
                  |> Repo.update()

                update_member_count(conversation_id)

                Phoenix.PubSub.broadcast(
                  Elektrine.PubSub,
                  "conversation:#{conversation_id}",
                  {:member_joined, user_id}
                )

                result
            end
        end
    end
  end

  def join_channel(channel_id, user_id) do
    with {:ok, conversation} <- get_conversation_basic(channel_id),
         true <- conversation.type == "channel",
         true <- conversation.is_public,
         nil <-
           from(cm in ChatConversationMember,
             where:
               cm.conversation_id == ^channel_id and cm.user_id == ^user_id and is_nil(cm.left_at)
           )
           |> Repo.one() do
      add_member_to_conversation(channel_id, user_id, "readonly")
    else
      false -> {:error, :not_public_channel}
      %ChatConversationMember{} -> {:error, :already_member}
      error -> error
    end
  end

  def pin_conversation(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil -> {:error, :unauthorized}
      member -> member |> ChatConversationMember.changeset(%{pinned: true}) |> Repo.update()
    end
  end

  def unpin_conversation(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil -> {:error, :unauthorized}
      member -> member |> ChatConversationMember.changeset(%{pinned: false}) |> Repo.update()
    end
  end

  def leave_conversation(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :not_a_member}

      member ->
        conversation = Repo.get(ChatConversation, conversation_id)

        if conversation && conversation.creator_id == user_id &&
             conversation.type in ["group", "channel"] do
          other_members =
            from(cm in ChatConversationMember,
              where:
                cm.conversation_id == ^conversation_id and cm.user_id != ^user_id and
                  is_nil(cm.left_at)
            )
            |> Repo.all()

          if other_members != [] do
            {:error, :owner_must_transfer}
          else
            complete_leave(member, conversation_id, user_id)
          end
        else
          complete_leave(member, conversation_id, user_id)
        end
    end
  end

  def user_has_conversations?(user_id) do
    from(cm in ChatConversationMember,
      join: c in ChatConversation,
      on: c.id == cm.conversation_id,
      where: cm.user_id == ^user_id and is_nil(cm.left_at),
      limit: 1,
      select: 1
    )
    |> Repo.exists?()
  end

  def admin?(conversation_id, user_id) do
    member =
      from(cm in ChatConversationMember,
        where:
          cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and is_nil(cm.left_at)
      )
      |> Repo.one()

    match?(%ChatConversationMember{role: "admin"}, member)
  end

  defp complete_leave(member, conversation_id, user_id) do
    result = member |> ChatConversationMember.remove_member_changeset() |> Repo.update()

    case result do
      {:ok, _} ->
        update_member_count(conversation_id)
        _ = Federation.publish_membership_state(conversation_id, user_id, "left")
        result

      error ->
        error
    end
  end

  defp filter_blocked_conversations(conversations, user_id) do
    Enum.filter(conversations, fn conversation ->
      case conversation.type do
        "dm" ->
          other_user =
            Enum.find(conversation.members, fn member ->
              member.user_id != user_id and is_nil(member.left_at)
            end)

          case other_user do
            nil ->
              true

            %{user_id: other_user_id} ->
              not (Elektrine.Accounts.user_blocked?(user_id, other_user_id) or
                     Elektrine.Accounts.user_blocked?(other_user_id, user_id))
          end

        _ ->
          true
      end
    end)
  end

  defp load_recent_conversation_messages(%ChatConversation{id: conversation_id}) do
    from(m in ChatMessage,
      where: m.conversation_id == ^conversation_id and is_nil(m.deleted_at),
      order_by: [desc: m.inserted_at],
      limit: 50,
      preload: [:sender, :link_preview, reply_to: [:sender], reactions: [:user, :remote_actor]]
    )
    |> Repo.all()
    |> ChatMessage.decrypt_messages()
  end

  defp get_conversation_basic(conversation_id) do
    case Repo.get(ChatConversation, conversation_id) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  defp do_add_member_to_conversation(
         conversation_id,
         user_id,
         role,
         added_by_user_id,
         publish_federation?
       ) do
    if Elektrine.Messaging.Moderation.user_banned?(conversation_id, user_id) do
      {:error, :banned}
    else
      existing_member =
        Repo.get_by(ChatConversationMember, conversation_id: conversation_id, user_id: user_id)

      case existing_member do
        nil ->
          ChatConversationMember.add_member_changeset(conversation_id, user_id, role)
          |> Repo.insert()
          |> case do
            {:ok, member} ->
              update_member_count(conversation_id)

              maybe_publish_federation_membership(
                publish_federation?,
                conversation_id,
                user_id,
                added_by_user_id,
                role
              )

              Phoenix.PubSub.broadcast(
                Elektrine.PubSub,
                "conversation:#{conversation_id}",
                {:member_joined, %{user_id: user_id, conversation_id: conversation_id}}
              )

              Phoenix.PubSub.broadcast(
                Elektrine.PubSub,
                "user:#{user_id}",
                {:added_to_conversation, %{conversation_id: conversation_id}}
              )

              {:ok, member}

            error ->
              error
          end

        member ->
          member
          |> ChatConversationMember.changeset(%{
            left_at: nil,
            joined_at: DateTime.utc_now(),
            role: role
          })
          |> Repo.update()
          |> case do
            {:ok, updated_member} ->
              update_member_count(conversation_id)

              maybe_publish_federation_membership(
                publish_federation?,
                conversation_id,
                user_id,
                added_by_user_id,
                role
              )

              Phoenix.PubSub.broadcast(
                Elektrine.PubSub,
                "conversation:#{conversation_id}",
                {:member_joined, %{user_id: user_id, conversation_id: conversation_id}}
              )

              Phoenix.PubSub.broadcast(
                Elektrine.PubSub,
                "user:#{user_id}",
                {:added_to_conversation, %{conversation_id: conversation_id}}
              )

              {:ok, updated_member}

            error ->
              error
          end
      end
    end
  end

  defp maybe_publish_invite_acceptance(_conversation_id, _user_id, nil, _role), do: :ok

  defp maybe_publish_invite_acceptance(conversation_id, user_id, added_by_user_id, role)
       when is_integer(conversation_id) and is_integer(user_id) and is_integer(added_by_user_id) do
    if user_id != added_by_user_id do
      Federation.publish_invite_state(
        conversation_id,
        user_id,
        added_by_user_id,
        "accepted",
        role,
        %{"source" => "local_member_add"}
      )
    else
      :ok
    end
  end

  defp maybe_publish_federation_membership(true, conversation_id, user_id, added_by_user_id, role) do
    maybe_publish_invite_acceptance(conversation_id, user_id, added_by_user_id, role)
    _ = Federation.publish_membership_state(conversation_id, user_id, "active", role)
    :ok
  end

  defp maybe_publish_federation_membership(false, _conversation_id, _user_id, _actor_id, _role),
    do: :ok

  defp membership_state_for_departure(%ChatConversationMember{role: role})
       when role in ["owner", "admin"], do: "left"

  defp membership_state_for_departure(_member), do: "left"

  defp remote_mirror_channel_join?(%ChatConversation{
         type: "channel",
         is_federated_mirror: true,
         server_id: server_id
       })
       when is_integer(server_id), do: true

  defp remote_mirror_channel_join?(_conversation), do: false

  defp request_mirrored_channel_join(%ChatConversation{} = conversation, user_id)
       when is_integer(user_id) do
    case get_conversation_member(conversation.id, user_id) do
      %ChatConversationMember{} ->
        {:error, :already_member}

      nil ->
        role = "member"

        with false <- local_join_request_pending?(conversation.id, user_id),
             %User{} = user <- Repo.get(User, user_id),
             :ok <-
               FederationState.persist_local_invite_projection(
                 conversation.id,
                 user.id,
                 user.id,
                 "pending",
                 role,
                 %{"source" => "remote_join_request"},
                 %{local_domain: &Federation.local_domain/0}
               ) do
          _ = Federation.publish_membership_state(conversation.id, user.id, "invited", role)
          {:ok, :pending}
        else
          true -> {:ok, :pending}
          nil -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_event_payload}
        end
    end
  end

  defp request_mirrored_channel_join(_conversation, _user_id),
    do: {:error, :invalid_event_payload}

  defp review_remote_join_request(conversation_id, remote_actor_id, reviewer_user_id, decision)
       when decision in ["accepted", "declined"] do
    with {:ok, conversation} <- remote_join_review_conversation(conversation_id),
         %User{} <- Repo.get(User, reviewer_user_id),
         %FederationMembershipState{} = membership_state <-
           pending_remote_join_membership_state(conversation_id, remote_actor_id),
         %ActivityPubActor{} = remote_actor <- Repo.get(ActivityPubActor, remote_actor_id) do
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second)
      membership_state_value = if decision == "accepted", do: "active", else: "left"

      updated_metadata =
        membership_state.metadata
        |> normalize_remote_join_metadata()
        |> Map.merge(%{
          "join_request" => false,
          "join_decision" => decision,
          "reviewed_by_user_id" => reviewer_user_id,
          "reviewed_at" => DateTime.to_iso8601(timestamp)
        })

      updated_joined_at =
        if decision == "accepted",
          do: membership_state.joined_at_remote || timestamp,
          else: membership_state.joined_at_remote

      case membership_state
           |> FederationMembershipState.changeset(%{
             state: membership_state_value,
             joined_at_remote: updated_joined_at,
             updated_at_remote: timestamp,
             metadata: updated_metadata
           })
           |> Repo.update() do
        {:ok, updated_membership_state} ->
          _ = broadcast_remote_join_request_update(conversation.id, updated_membership_state)

          _ =
            Federation.publish_remote_invite_state(
              conversation.id,
              remote_join_actor_payload(remote_actor),
              reviewer_user_id,
              decision,
              membership_state.role || "member",
              outbound_remote_join_decision_metadata(updated_metadata)
            )

          {:ok, format_pending_remote_join_request(updated_membership_state)}

        {:error, _changeset} ->
          {:error, :update_failed}
      end
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      _ -> {:error, :not_found}
    end
  end

  defp pending_remote_join_membership_state(conversation_id, remote_actor_id)
       when is_integer(conversation_id) and is_integer(remote_actor_id) do
    from(state in FederationMembershipState,
      where:
        state.conversation_id == ^conversation_id and state.remote_actor_id == ^remote_actor_id and
          state.state == "invited",
      preload: [:remote_actor]
    )
    |> Repo.one()
    |> case do
      %FederationMembershipState{} = membership_state ->
        if pending_remote_join_request?(membership_state), do: membership_state, else: nil

      nil ->
        nil
    end
  end

  defp pending_remote_join_membership_state(_, _), do: nil

  defp remote_join_review_conversation(conversation_id) when is_integer(conversation_id) do
    case Repo.get(ChatConversation, conversation_id) do
      %ChatConversation{type: "channel", is_federated_mirror: false, server_id: server_id} =
          conversation
      when is_integer(server_id) ->
        {:ok, conversation}

      _ ->
        {:error, :not_found}
    end
  end

  defp remote_join_review_conversation(_conversation_id), do: {:error, :not_found}

  defp pending_remote_join_request?(%FederationMembershipState{metadata: metadata})
       when is_map(metadata), do: metadata["join_request"] in [true, "true"]

  defp pending_remote_join_request?(_membership_state), do: false

  defp format_pending_remote_join_request(%FederationMembershipState{} = membership_state) do
    actor = membership_state.remote_actor

    handle =
      case actor do
        %ActivityPubActor{username: username, domain: domain}
        when is_binary(username) and is_binary(domain) ->
          "@#{username}@#{domain}"

        _ ->
          nil
      end

    display_name =
      case actor do
        %ActivityPubActor{display_name: display_name} when is_binary(display_name) ->
          if Elektrine.Strings.present?(display_name), do: display_name, else: nil

        %ActivityPubActor{username: username} when is_binary(username) ->
          if Elektrine.Strings.present?(username), do: username, else: nil

        _ ->
          handle || "remote user"
      end
      |> case do
        nil -> handle || "remote user"
        value -> value
      end

    %{
      remote_actor_id: membership_state.remote_actor_id,
      actor_uri: actor && actor.uri,
      origin_domain: membership_state.origin_domain,
      role: membership_state.role,
      state: membership_state.state,
      handle: handle,
      display_name: display_name,
      display_label: remote_join_display_label(display_name, handle),
      avatar_url: actor && actor.avatar_url,
      requested_at: membership_state.inserted_at,
      updated_at: membership_state.updated_at_remote || membership_state.updated_at,
      metadata: membership_state.metadata || %{}
    }
  end

  defp format_pending_remote_join_request(_membership_state), do: %{}

  defp remote_join_display_label(display_name, handle)
       when is_binary(display_name) and is_binary(handle) do
    if Elektrine.Strings.present?(display_name) and display_name != handle,
      do: "#{display_name} (#{handle})",
      else: handle
  end

  defp remote_join_display_label(display_name, _handle) when is_binary(display_name),
    do: display_name

  defp remote_join_display_label(_display_name, handle) when is_binary(handle), do: handle
  defp remote_join_display_label(_display_name, _handle), do: "remote user"

  defp normalize_remote_join_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_remote_join_metadata(_metadata), do: %{}

  defp outbound_remote_join_decision_metadata(metadata) when is_map(metadata),
    do:
      metadata
      |> Map.drop(["reviewed_by_user_id", "reviewed_at"])
      |> Map.put("source", "moderator_review")

  defp outbound_remote_join_decision_metadata(_metadata), do: %{"source" => "moderator_review"}

  defp remote_join_actor_payload(%ActivityPubActor{} = actor) do
    %{
      "uri" => actor.uri,
      "username" => actor.username,
      "domain" => actor.domain,
      "handle" => "#{actor.username}@#{actor.domain}",
      "display_name" => actor.display_name || actor.username
    }
    |> maybe_put_actor_avatar(actor.avatar_url)
  end

  defp remote_join_actor_payload(_actor), do: %{}

  defp maybe_put_actor_avatar(payload, avatar_url) when is_binary(avatar_url) do
    if Elektrine.Strings.present?(avatar_url),
      do: Map.put(payload, "avatar_url", avatar_url),
      else: payload
  end

  defp maybe_put_actor_avatar(payload, _avatar_url), do: payload

  defp broadcast_remote_join_request_update(
         conversation_id,
         %FederationMembershipState{} = membership_state
       )
       when is_integer(conversation_id) do
    case Repo.get(ActivityPubActor, membership_state.remote_actor_id) do
      %ActivityPubActor{} = actor ->
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversation:#{conversation_id}",
          {:federation_membership_update,
           %{
             conversation_id: conversation_id,
             remote_actor_id: membership_state.remote_actor_id,
             handle: "@#{actor.username}@#{actor.domain}",
             role: membership_state.role,
             state: membership_state.state,
             joined_at: membership_state.joined_at_remote,
             updated_at: membership_state.updated_at_remote,
             avatar_url: actor.avatar_url
           }}
        )

        :ok

      _ ->
        :ok
    end
  end

  defp broadcast_remote_join_request_update(_conversation_id, _membership_state), do: :ok

  defp local_join_request_pending?(conversation_id, user_id)
       when is_integer(conversation_id) and is_integer(user_id) do
    case Repo.get(User, user_id) do
      %User{} = user ->
        target_uri = local_actor_uri(user)

        Repo.exists?(
          from(invite in FederationInviteState,
            where:
              invite.conversation_id == ^conversation_id and invite.target_uri == ^target_uri and
                invite.state == "pending"
          )
        )

      _ ->
        false
    end
  end

  defp local_join_request_pending?(_conversation_id, _user_id), do: false

  defp local_actor_uri(%User{username: username}) when is_binary(username),
    do: "#{ActivityPub.instance_url()}/users/#{username}"

  defp maybe_publish_role_assignment(_conversation_id, _user_id, _new_role, nil), do: :ok

  defp maybe_publish_role_assignment(conversation_id, user_id, new_role, actor_user_id)
       when is_integer(conversation_id) and is_integer(user_id) and is_binary(new_role) and
              is_integer(actor_user_id) do
    with %ChatConversation{type: "channel", server_id: server_id} <-
           Repo.get(ChatConversation, conversation_id),
         true <- is_integer(server_id),
         %User{} = target_user <- Repo.get(User, user_id),
         %User{} = actor_user <- Repo.get(User, actor_user_id),
         %{} = role_definition <- builtin_room_role_definition(new_role) do
      role_upsert_payload = %{"role" => role_definition}

      role_assignment_payload = %{
        "assignment" => %{
          "role_id" => role_definition["id"],
          "target" => %{
            "type" => "member",
            "id" => FederationUtils.sender_payload(target_user)["uri"]
          },
          "state" => "assigned"
        }
      }

      _ =
        Federation.publish_extension_event(
          conversation_id,
          actor_user.id,
          "role.upsert",
          role_upsert_payload
        )

      _ =
        Federation.publish_extension_event(
          conversation_id,
          actor_user.id,
          "role.assignment.upsert",
          role_assignment_payload
        )
    end

    :ok
  end

  defp maybe_publish_role_assignment(_conversation_id, _user_id, _new_role, _actor_user_id),
    do: :ok

  defp builtin_room_role_definition("owner"),
    do: %{
      "id" => "builtin:owner",
      "name" => "Owner",
      "permissions" => [
        "manage_roles",
        "manage_permissions",
        "manage_moderation",
        "manage_messages",
        "manage_channels",
        "manage_threads",
        "create_threads",
        "view_audit_log",
        "manage_webhooks",
        "manage_server",
        "invite_members",
        "send_messages",
        "send_tts_messages",
        "send_voice_signaling",
        "attach_files",
        "embed_links",
        "mention_everyone",
        "use_external_emoji"
      ],
      "position" => 100
    }

  defp builtin_room_role_definition("admin"),
    do: %{
      "id" => "builtin:admin",
      "name" => "Admin",
      "permissions" => [
        "manage_roles",
        "manage_permissions",
        "manage_moderation",
        "manage_messages",
        "manage_channels",
        "manage_threads",
        "create_threads",
        "view_audit_log",
        "manage_webhooks",
        "invite_members",
        "send_messages",
        "send_tts_messages",
        "send_voice_signaling",
        "attach_files",
        "embed_links",
        "mention_everyone",
        "use_external_emoji"
      ],
      "position" => 80
    }

  defp builtin_room_role_definition("moderator"),
    do: %{
      "id" => "builtin:moderator",
      "name" => "Moderator",
      "permissions" => [
        "manage_moderation",
        "manage_messages",
        "manage_threads",
        "invite_members",
        "send_messages",
        "attach_files",
        "embed_links",
        "use_external_emoji"
      ],
      "position" => 60
    }

  defp builtin_room_role_definition("member"),
    do: %{
      "id" => "builtin:member",
      "name" => "Member",
      "permissions" => ["send_messages", "attach_files", "embed_links", "use_external_emoji"],
      "position" => 10
    }

  defp builtin_room_role_definition("readonly"),
    do: %{
      "id" => "builtin:readonly",
      "name" => "Readonly",
      "permissions" => ["read_messages"],
      "position" => 0
    }

  defp builtin_room_role_definition(_role), do: nil

  defp update_member_count(conversation_id) do
    count =
      from(cm in ChatConversationMember,
        where: cm.conversation_id == ^conversation_id and is_nil(cm.left_at),
        select: count()
      )
      |> Repo.one()

    conversation = Repo.get(ChatConversation, conversation_id)

    if count == 0 && conversation && conversation.type in ["group", "channel"] do
      from(m in ChatMessage, where: m.conversation_id == ^conversation_id) |> Repo.delete_all()

      from(cm in ChatConversationMember, where: cm.conversation_id == ^conversation_id)
      |> Repo.delete_all()

      Repo.delete(conversation)

      Phoenix.PubSub.broadcast(
        Elektrine.PubSub,
        "conversations:all",
        {:conversation_deleted, conversation_id}
      )

      {:deleted, 0}
    else
      from(c in ChatConversation, where: c.id == ^conversation_id)
      |> Repo.update_all(set: [member_count: count])

      {:updated, count}
    end
  end

  defp normalize_remote_dm_handle(handle) when is_binary(handle) do
    normalized = handle |> String.trim() |> String.trim_leading("@") |> String.downcase()

    case Regex.run(~r/^([a-z0-9_]{1,64})@([a-z0-9.-]+\.[a-z]{2,})$/, normalized) do
      [_, username, domain] ->
        {:ok, %{username: username, domain: domain, handle: "#{username}@#{domain}"}}

      _ ->
        {:error, :invalid_remote_handle}
    end
  end

  defp normalize_remote_dm_handle(_), do: {:error, :invalid_remote_handle}

  defp ensure_dm_creation_allowed(user_id),
    do: if(RateLimiter.can_create_dm?(user_id), do: :ok, else: {:error, :rate_limited})

  defp ensure_remote_recipient_domain(_local_user_id, recipient) do
    case local_recipient_user(recipient) do
      %User{} = user -> {:redirect_local_dm, user.id}
      :local_domain -> {:error, :user_not_found}
      :local_custom_domain -> {:error, :user_not_found}
      _ -> :ok
    end
  end

  defp local_domain?(domain) when is_binary(domain),
    do: String.downcase(domain) == Federation.local_domain()

  defp local_domain?(_), do: false

  defp local_recipient_user(%{domain: domain, username: username})
       when is_binary(domain) and is_binary(username) do
    normalized_domain = String.downcase(domain)

    if local_domain?(normalized_domain) do
      Accounts.get_user_by_username(username) || :local_domain
    else
      case Profiles.get_verified_custom_domain(normalized_domain) do
        %{user: %{username: ^username} = user} -> user
        %{domain: ^normalized_domain} -> :local_custom_domain
        _ -> nil
      end
    end
  end

  defp local_recipient_user(_recipient), do: nil

  defp remote_dm_display_name(attrs, recipient) when is_map(attrs) do
    display_name = attrs[:display_name] || attrs["display_name"] || attrs[:name] || attrs["name"]

    if Elektrine.Strings.present?(display_name),
      do: String.trim(display_name),
      else: "@" <> recipient.handle
  end

  defp remote_dm_display_name(_attrs, recipient), do: "@" <> recipient.handle

  defp remote_dm_avatar_url(attrs) when is_map(attrs),
    do: attrs[:avatar_url] || attrs["avatar_url"]

  defp remote_dm_avatar_url(_), do: nil
end
