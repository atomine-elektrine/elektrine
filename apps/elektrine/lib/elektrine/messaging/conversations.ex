defmodule Elektrine.Messaging.Conversations do
  @moduledoc "Context for managing conversations - creation, updates, membership, and discovery.\n"
  import Ecto.Query, warn: false
  alias Elektrine.Repo

  alias Elektrine.Messaging.{
    Conversation,
    ConversationMember,
    Message,
    RateLimiter,
    UserHiddenMessage
  }

  alias Elektrine.Accounts.User
  @doc "Returns the list of conversations for a user.\n"
  def list_conversations(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    query =
      from(c in Conversation,
        join: cm in ConversationMember,
        on: c.id == cm.conversation_id and cm.user_id == ^user_id,
        where: is_nil(cm.left_at),
        order_by: [desc: cm.pinned, desc: c.last_message_at, desc: c.updated_at],
        limit: ^limit,
        preload: [members: [user: [:profile]]]
      )

    conversations = Repo.all(query)
    conversation_ids = Enum.map(conversations, & &1.id)

    latest_messages =
      from(m in Message,
        left_join: h in UserHiddenMessage,
        on: h.message_id == m.id and h.user_id == ^user_id,
        where: m.conversation_id in ^conversation_ids and is_nil(m.deleted_at) and is_nil(h.id),
        distinct: m.conversation_id,
        order_by: [asc: m.conversation_id, desc: m.inserted_at],
        preload: [sender: [:profile]]
      )
      |> Repo.all()
      |> Message.decrypt_messages()
      |> Enum.group_by(& &1.conversation_id)

    Enum.map(conversations, fn conversation ->
      messages = Map.get(latest_messages, conversation.id, [])
      %{conversation | messages: messages}
    end)
    |> filter_blocked_conversations(user_id)
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

  @doc "Gets a single conversation with members and recent messages.\n\nNote: For chat loading, prefer `get_conversation_for_chat!/2` which is faster\nas it doesn't preload messages (messages are loaded separately with pagination).\n"
  def get_conversation!(id, user_id) do
    query =
      from(c in Conversation,
        join: cm in ConversationMember,
        on: c.id == cm.conversation_id and cm.user_id == ^user_id,
        where: c.id == ^id and is_nil(cm.left_at),
        preload: [
          creator: [],
          members: [user: [:profile]],
          messages:
            ^from(m in Message,
              left_join: h in UserHiddenMessage,
              on: h.message_id == m.id and h.user_id == ^user_id,
              where: is_nil(m.deleted_at) and is_nil(h.id),
              order_by: [desc: m.inserted_at],
              limit: 50,
              preload: [
                sender: [:profile],
                reply_to: [sender: [:profile]],
                reactions: [user: []],
                link_preview: [],
                shared_message: [sender: [:profile], conversation: []]
              ]
            )
        ]
      )

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      conversation ->
        decrypted_messages = Message.decrypt_messages(conversation.messages)
        conversation = %{conversation | messages: decrypted_messages}
        {:ok, conversation}
    end
  end

  @doc "Gets a conversation for chat display without preloading messages.\n\nThis is a lightweight version of get_conversation!/2 optimized for the chat view\nwhere messages are loaded separately via get_conversation_messages/3.\n\nReturns the conversation with members preloaded, but messages as empty list.\n"
  def get_conversation_for_chat!(id, user_id) do
    query =
      from(c in Conversation,
        join: cm in ConversationMember,
        on: c.id == cm.conversation_id and cm.user_id == ^user_id,
        where: c.id == ^id and is_nil(cm.left_at),
        preload: [creator: [], members: [user: [:profile]]]
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      conversation -> {:ok, %{conversation | messages: []}}
    end
  end

  @doc "Gets a conversation by its hash.\n"
  def get_conversation_by_hash(hash) do
    from(c in Conversation, where: c.hash == ^hash, preload: [:creator, members: :user])
    |> Repo.one()
  end

  @doc "Gets a conversation by its name (case-insensitive, for communities).\n"
  def get_conversation_by_name(name) do
    normalized_name = String.downcase(name)

    from(c in Conversation,
      where: fragment("LOWER(?)", c.name) == ^normalized_name,
      preload: [:creator]
    )
    |> Repo.one()
  end

  @doc "Gets moderators and admins for a community (for ActivityPub moderators collection).\n"
  def get_community_moderators(community_id) do
    from(cm in ConversationMember,
      where:
        cm.conversation_id == ^community_id and cm.role in ["owner", "admin", "moderator"] and
          is_nil(cm.left_at),
      preload: [:user],
      order_by: [
        asc:
          fragment(
            "CASE WHEN ? = 'owner' THEN 1 WHEN ? = 'admin' THEN 2 ELSE 3 END",
            cm.role,
            cm.role
          )
      ]
    )
    |> Repo.all()
  end

  @doc "Gets a basic conversation without preloads.\n"
  def get_conversation_basic(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      nil -> {:error, :not_found}
      conversation -> {:ok, conversation}
    end
  end

  @doc "Creates a direct message conversation between two users.\n"
  def create_dm_conversation(user1_id, user2_id) do
    if RateLimiter.can_create_dm?(user1_id) do
      case Elektrine.Privacy.can_send_dm?(user1_id, user2_id) do
        {:error, reason} ->
          {:error, reason}

        {:ok, :allowed} ->
          existing_dm =
            from(c in Conversation,
              join: cm1 in ConversationMember,
              on: c.id == cm1.conversation_id,
              join: cm2 in ConversationMember,
              on: c.id == cm2.conversation_id,
              where:
                c.type == "dm" and cm1.user_id == ^user1_id and is_nil(cm1.left_at) and
                  cm2.user_id == ^user2_id and is_nil(cm2.left_at),
              limit: 1
            )

          case Repo.one(existing_dm) do
            %Conversation{} = conversation ->
              {:ok, conversation}

            nil ->
              RateLimiter.record_dm_creation(user1_id)

              Repo.transaction(fn ->
                {:ok, conversation} =
                  %Conversation{}
                  |> Conversation.dm_changeset(%{creator_id: user1_id})
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

  @doc "Checks if user can create more conversations of the given type.\nReturns :ok if allowed, {:error, :limit_exceeded} otherwise.\n"
  def check_creation_limit(user_id, type) do
    max_channels = 10
    max_groups = 20

    case type do
      "channel" ->
        count =
          from(c in Conversation,
            where: c.creator_id == ^user_id and c.type == "channel",
            select: count(c.id)
          )
          |> Repo.one()

        if count < max_channels do
          :ok
        else
          {:error, :limit_exceeded}
        end

      "group" ->
        count =
          from(c in Conversation,
            where: c.creator_id == ^user_id and c.type == "group",
            select: count(c.id)
          )
          |> Repo.one()

        if count < max_groups do
          :ok
        else
          {:error, :limit_exceeded}
        end

      _ ->
        :ok
    end
  end

  @doc "Creates a group conversation.\n"
  def create_group_conversation(creator_id, attrs, member_ids \\ []) do
    case check_creation_limit(creator_id, "group") do
      :ok ->
        attrs = Map.put(attrs, :creator_id, creator_id)

        Repo.transaction(fn ->
          {:ok, conversation} =
            %Conversation{} |> Conversation.group_changeset(attrs) |> Repo.insert()

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

  @doc "Creates a channel.\n"
  def create_channel(creator_id, attrs) do
    case check_creation_limit(creator_id, "channel") do
      :ok ->
        attrs = Map.put(attrs, :creator_id, creator_id)

        Repo.transaction(fn ->
          {:ok, conversation} =
            %Conversation{} |> Conversation.channel_changeset(attrs) |> Repo.insert()

          {:ok, _} = add_member_to_conversation(conversation.id, creator_id, "admin")
          update_member_count(conversation.id)
          conversation
        end)

      {:error, :limit_exceeded} ->
        {:error, :channel_limit_exceeded}
    end
  end

  @doc "Updates a conversation (name, description, etc.).\n"
  def update_conversation(conversation, attrs) do
    conversation |> Conversation.changeset(attrs) |> Repo.update()
  end

  @doc "Deletes a conversation (admin/creator only).\n"
  def delete_conversation(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      nil -> {:error, :not_found}
      conversation -> Repo.delete(conversation)
    end
  end

  @doc "Lists public channels.\n"
  def list_public_channels(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(c in Conversation,
      where: c.type == "channel" and c.is_public == true and is_nil(c.server_id),
      order_by: [desc: c.member_count, desc: c.last_message_at],
      limit: ^limit,
      preload: [:creator]
    )
    |> Repo.all()
  end

  @doc "Lists public groups.\n"
  def list_public_groups(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    from(c in Conversation,
      where:
        c.type == "group" and c.is_public == true and c.type not in ["timeline", "community"],
      order_by: [desc: c.member_count, desc: c.last_message_at],
      limit: ^limit,
      preload: [:creator]
    )
    |> Repo.all()
  end

  @doc "Searches for public groups and channels that the user can join.\n"
  def search_public_conversations(query, current_user_id, limit \\ 10) do
    search_term = "%#{query}%"

    user_conversation_ids =
      from(cm in ConversationMember,
        where: cm.user_id == ^current_user_id and is_nil(cm.left_at),
        select: cm.conversation_id
      )
      |> Repo.all()

    from(c in Conversation,
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

  @doc "Adds a member to a conversation.\n"
  def add_member_to_conversation(
        conversation_id,
        user_id,
        role \\ "member",
        added_by_user_id \\ nil
      ) do
    if added_by_user_id do
      case Elektrine.Privacy.can_add_to_group?(added_by_user_id, user_id) do
        {:error, reason} -> {:error, reason}
        {:ok, :allowed} -> do_add_member_to_conversation(conversation_id, user_id, role)
      end
    else
      do_add_member_to_conversation(conversation_id, user_id, role)
    end
  end

  defp do_add_member_to_conversation(conversation_id, user_id, role) do
    existing_member =
      Repo.get_by(ConversationMember, conversation_id: conversation_id, user_id: user_id)

    case existing_member do
      nil ->
        ConversationMember.add_member_changeset(conversation_id, user_id, role)
        |> Repo.insert()
        |> case do
          {:ok, member} ->
            update_member_count(conversation_id)

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
        |> ConversationMember.changeset(%{
          left_at: nil,
          joined_at: DateTime.utc_now(),
          role: role
        })
        |> Repo.update()
        |> case do
          {:ok, updated_member} ->
            update_member_count(conversation_id)

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

  @doc "Removes a member from a conversation.\n"
  def remove_member_from_conversation(conversation_id, user_id) do
    member =
      from(cm in ConversationMember,
        where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id
      )
      |> Repo.one()

    case member do
      nil ->
        {:error, :not_found}

      member ->
        member
        |> ConversationMember.remove_member_changeset()
        |> Repo.update()
        |> case do
          {:ok, updated_member} ->
            update_member_count(conversation_id)

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

  @doc "Gets a conversation member record.\n"
  def get_conversation_member(conversation_id, user_id) do
    from(cm in ConversationMember,
      where:
        cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and is_nil(cm.left_at)
    )
    |> Repo.one()
  end

  @doc "Gets all members of a conversation.\n"
  def get_conversation_members(conversation_id) do
    from(cm in ConversationMember,
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

  @doc "Promotes a member to admin role.\n"
  def promote_to_admin(conversation_id, user_id, promoter_id) do
    with {:ok, _conversation} <- get_conversation_basic(conversation_id),
         true <- admin?(conversation_id, promoter_id) do
      member =
        from(cm in ConversationMember,
          where:
            cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and
              is_nil(cm.left_at)
        )
        |> Repo.one()

      case member do
        nil -> {:error, :not_found}
        member -> member |> ConversationMember.changeset(%{role: "admin"}) |> Repo.update()
      end
    else
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  @doc "Demotes an admin to regular member.\n"
  def demote_from_admin(conversation_id, user_id, demoter_id) do
    with {:ok, conversation} <- get_conversation_basic(conversation_id),
         true <- admin?(conversation_id, demoter_id),
         false <- conversation.creator_id == user_id do
      member =
        from(cm in ConversationMember,
          where:
            cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and
              is_nil(cm.left_at)
        )
        |> Repo.one()

      case member do
        nil -> {:error, :not_found}
        member -> member |> ConversationMember.changeset(%{role: "member"}) |> Repo.update()
      end
    else
      true -> {:error, :cannot_demote_creator}
      false -> {:error, :unauthorized}
      error -> error
    end
  end

  @doc "Updates a member's role in a conversation.\n"
  def update_member_role(conversation_id, user_id, new_role) do
    case get_conversation_member(conversation_id, user_id) do
      nil -> {:error, :member_not_found}
      member -> member |> ConversationMember.changeset(%{role: new_role}) |> Repo.update()
    end
  end

  @doc "Promotes a user to moderator.\n"
  def promote_to_moderator(conversation_id, user_id) do
    update_member_role(conversation_id, user_id, "moderator")
  end

  @doc "Demotes a moderator to member.\n"
  def demote_from_moderator(conversation_id, user_id) do
    update_member_role(conversation_id, user_id, "member")
  end

  @doc "Joins a public conversation (channel or group).\n"
  def join_conversation(conversation_id, user_id) do
    case get_conversation_basic(conversation_id) do
      {:error, _} = error ->
        error

      {:ok, conversation} ->
        cond do
          conversation.type == "channel" and not is_nil(conversation.server_id) ->
            {:error, :must_join_server}

          conversation.type not in ["channel", "group", "community"] ->
            {:error, :not_joinable}

          conversation.is_public != true ->
            {:error, :not_public_channel}

          true ->
            existing_member =
              from(cm in ConversationMember,
                where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id
              )
              |> Repo.one()

            case existing_member do
              nil ->
                role =
                  if conversation.type == "channel" do
                    "readonly"
                  else
                    "member"
                  end

                result = add_member_to_conversation(conversation_id, user_id, role)

                case result do
                  {:ok, _} ->
                    Phoenix.PubSub.broadcast(
                      Elektrine.PubSub,
                      "conversation:#{conversation_id}",
                      {:member_joined, user_id}
                    )

                  _ ->
                    :ok
                end

                result

              %ConversationMember{left_at: nil} ->
                {:error, :already_member}

              %ConversationMember{left_at: _left_at} ->
                result =
                  existing_member
                  |> ConversationMember.changeset(%{left_at: nil, joined_at: DateTime.utc_now()})
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

  @doc "Joins a public channel.\n"
  def join_channel(channel_id, user_id) do
    with {:ok, conversation} <- get_conversation_basic(channel_id),
         true <- conversation.type == "channel",
         true <- conversation.is_public,
         nil <-
           from(cm in ConversationMember,
             where:
               cm.conversation_id == ^channel_id and cm.user_id == ^user_id and is_nil(cm.left_at)
           )
           |> Repo.one() do
      add_member_to_conversation(channel_id, user_id, "readonly")
    else
      false -> {:error, :not_public_channel}
      %ConversationMember{} -> {:error, :already_member}
      error -> error
    end
  end

  @doc "Pins a conversation for a user.\n"
  def pin_conversation(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil -> {:error, :unauthorized}
      member -> member |> ConversationMember.changeset(%{pinned: true}) |> Repo.update()
    end
  end

  @doc "Unpins a conversation for a user.\n"
  def unpin_conversation(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil -> {:error, :unauthorized}
      member -> member |> ConversationMember.changeset(%{pinned: false}) |> Repo.update()
    end
  end

  @doc "Allows a user to leave a conversation.\nSets the left_at timestamp on their membership record.\n"
  def leave_conversation(conversation_id, user_id) do
    case get_conversation_member(conversation_id, user_id) do
      nil ->
        {:error, :not_a_member}

      member ->
        conversation = Repo.get(Conversation, conversation_id)

        if conversation && conversation.creator_id == user_id &&
             conversation.type in ["group", "channel"] do
          other_members =
            from(cm in ConversationMember,
              where:
                cm.conversation_id == ^conversation_id and cm.user_id != ^user_id and
                  is_nil(cm.left_at)
            )
            |> Repo.all()

          if other_members != [] do
            {:error, :owner_must_transfer}
          else
            result = member |> ConversationMember.remove_member_changeset() |> Repo.update()

            case result do
              {:ok, _} ->
                update_member_count(conversation_id)
                result

              error ->
                error
            end
          end
        else
          result = member |> ConversationMember.remove_member_changeset() |> Repo.update()

          case result do
            {:ok, _} ->
              update_member_count(conversation_id)
              result

            error ->
              error
          end
        end
    end
  end

  @doc "Checks if a user is the owner of a community.\n"
  def community_owner?(conversation_id, user_id) do
    conversation = Repo.get(Conversation, conversation_id)
    conversation && conversation.creator_id == user_id
  end

  @doc "Checks if a user has any community memberships.\nFast check for loading skeleton optimization.\n"
  def user_has_communities?(user_id) do
    from(cm in ConversationMember,
      join: c in Conversation,
      on: c.id == cm.conversation_id,
      where: cm.user_id == ^user_id and c.type == "community" and is_nil(cm.left_at),
      limit: 1,
      select: 1
    )
    |> Repo.exists?()
  end

  @doc "Checks if there are any communities in the system.\nFast check for loading skeleton optimization.\n"
  def has_any_communities? do
    from(c in Conversation, where: c.type == "community", limit: 1, select: 1) |> Repo.exists?()
  end

  @doc "Checks if a user has any chat conversations (excludes timeline/community).\nFast check for loading skeleton optimization.\n"
  def user_has_conversations?(user_id) do
    from(cm in ConversationMember,
      join: c in Conversation,
      on: c.id == cm.conversation_id,
      where:
        cm.user_id == ^user_id and is_nil(cm.left_at) and c.type not in ["timeline", "community"],
      limit: 1,
      select: 1
    )
    |> Repo.exists?()
  end

  @doc "Checks if a user is an admin of a conversation.\n"
  def admin?(conversation_id, user_id) do
    member =
      from(cm in ConversationMember,
        where:
          cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and is_nil(cm.left_at)
      )
      |> Repo.one()

    case member do
      %ConversationMember{role: "admin"} -> true
      _ -> false
    end
  end

  defp update_member_count(conversation_id) do
    count =
      from(cm in ConversationMember,
        where: cm.conversation_id == ^conversation_id and is_nil(cm.left_at),
        select: count()
      )
      |> Repo.one()

    conversation = Repo.get(Conversation, conversation_id)

    cond do
      count == 0 && conversation && conversation.type in ["group", "channel"] ->
        from(m in Message, where: m.conversation_id == ^conversation_id) |> Repo.delete_all()

        from(cm in ConversationMember, where: cm.conversation_id == ^conversation_id)
        |> Repo.delete_all()

        Repo.delete(conversation)

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversations:all",
          {:conversation_deleted, conversation_id}
        )

        {:deleted, 0}

      count == 0 && conversation && conversation.type == "community" ->
        from(c in Conversation, where: c.id == ^conversation_id)
        |> Repo.update_all(set: [archived: true, member_count: 0])

        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "conversations:all",
          {:conversation_archived, conversation_id}
        )

        {:archived, 0}

      true ->
        from(c in Conversation, where: c.id == ^conversation_id)
        |> Repo.update_all(set: [member_count: count])

        {:updated, count}
    end
  end
end
