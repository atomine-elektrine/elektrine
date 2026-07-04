defmodule Elektrine.Messaging.ChatThreadsTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Messaging
  alias Elektrine.Messaging.ChatMessage
  alias Elektrine.Messaging.ChatThread
  alias Elektrine.Messaging.ChatThreads
  alias Elektrine.Repo

  defp create_server_channel_with_member do
    owner = AccountsFixtures.user_fixture()
    member = AccountsFixtures.user_fixture()

    {:ok, server} = Messaging.create_server(owner.id, %{name: "thread-space", is_public: true})
    {:ok, _member} = Messaging.join_server(server.id, member.id)

    [channel | _] = server.channels

    %{owner: owner, member: member, server: server, channel: channel}
  end

  defp create_message!(conversation_id, sender_id, content) do
    {:ok, message} = Messaging.create_chat_text_message(conversation_id, sender_id, content)
    message
  end

  defp insert_thread!(channel, creator_id, attrs \\ %{}) do
    %ChatThread{}
    |> ChatThread.changeset(
      Map.merge(
        %{
          conversation_id: channel.id,
          creator_id: creator_id,
          title: "manual thread",
          last_activity_at: DateTime.utc_now()
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "create_thread_from_message/3" do
    test "server owner creates a thread rooted at a message" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()
      message = create_message!(channel.id, member.id, "let's take this to a thread")

      Phoenix.PubSub.subscribe(Elektrine.PubSub, "chat:#{channel.id}")

      assert {:ok, thread} = ChatThreads.create_thread_from_message(message.id, owner.id)
      assert thread.conversation_id == channel.id
      assert thread.root_message_id == message.id
      assert thread.creator_id == owner.id
      assert thread.title == "let's take this to a thread"
      refute thread.archived_at
      assert %DateTime{} = thread.last_activity_at

      thread_id = thread.id
      assert_receive {:thread_created, %ChatThread{id: ^thread_id}}
    end

    test "uses the provided title over the message snippet" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()
      message = create_message!(channel.id, member.id, "original content")

      assert {:ok, thread} =
               ChatThreads.create_thread_from_message(message.id, owner.id, %{
                 title: "Custom title"
               })

      assert thread.title == "Custom title"
    end

    test "regular members without create_threads cannot create threads" do
      %{member: member, channel: channel} = create_server_channel_with_member()
      message = create_message!(channel.id, member.id, "no thread for you")

      assert {:error, :unauthorized} =
               ChatThreads.create_thread_from_message(message.id, member.id)
    end

    test "a message can only root one thread" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()
      message = create_message!(channel.id, member.id, "root once")

      assert {:ok, _thread} = ChatThreads.create_thread_from_message(message.id, owner.id)

      assert {:error, :thread_exists} =
               ChatThreads.create_thread_from_message(message.id, owner.id)
    end

    test "threads are only available in channels" do
      creator = AccountsFixtures.user_fixture()
      buddy = AccountsFixtures.user_fixture()

      {:ok, group} =
        Messaging.create_chat_group_conversation(creator.id, %{name: "thread group"}, [buddy.id])

      message = create_message!(group.id, buddy.id, "group message")

      assert {:error, :unsupported_conversation_type} =
               ChatThreads.create_thread_from_message(message.id, creator.id)
    end

    test "unknown messages return not_found" do
      %{owner: owner} = create_server_channel_with_member()

      assert {:error, :not_found} = ChatThreads.create_thread_from_message(-1, owner.id)
    end
  end

  describe "create_thread/3" do
    test "creates a standalone thread without a root message" do
      %{owner: owner, channel: channel} = create_server_channel_with_member()

      assert {:ok, thread} = ChatThreads.create_thread(channel.id, owner.id, %{title: "Planning"})
      assert thread.title == "Planning"
      assert is_nil(thread.root_message_id)
    end
  end

  describe "archive_thread/2 and unarchive_thread/2" do
    test "the thread creator can archive and unarchive their own thread" do
      %{member: member, channel: channel} = create_server_channel_with_member()
      thread = insert_thread!(channel, member.id)

      Phoenix.PubSub.subscribe(Elektrine.PubSub, "chat:#{channel.id}")

      assert {:ok, archived} = ChatThreads.archive_thread(thread.id, member.id)
      assert %DateTime{} = archived.archived_at

      thread_id = thread.id
      assert_receive {:thread_archived, %ChatThread{id: ^thread_id}}

      assert {:ok, unarchived} = ChatThreads.unarchive_thread(thread.id, member.id)
      assert is_nil(unarchived.archived_at)
      assert_receive {:thread_updated, %ChatThread{id: ^thread_id}}
    end

    test "regular members cannot archive someone else's thread" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()
      thread = insert_thread!(channel, owner.id)

      assert {:error, :unauthorized} = ChatThreads.archive_thread(thread.id, member.id)
    end

    test "server staff can archive member-created threads" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()
      thread = insert_thread!(channel, member.id)

      assert {:ok, archived} = ChatThreads.archive_thread(thread.id, owner.id)
      assert %DateTime{} = archived.archived_at
    end

    test "archiving twice returns already_archived" do
      %{owner: owner, channel: channel} = create_server_channel_with_member()
      thread = insert_thread!(channel, owner.id)

      assert {:ok, _} = ChatThreads.archive_thread(thread.id, owner.id)
      assert {:error, :already_archived} = ChatThreads.archive_thread(thread.id, owner.id)
    end
  end

  describe "list_threads/2" do
    test "filters by active and archived state" do
      %{owner: owner, channel: channel} = create_server_channel_with_member()

      active = insert_thread!(channel, owner.id, %{title: "active thread"})
      archived = insert_thread!(channel, owner.id, %{title: "archived thread"})
      {:ok, _} = ChatThreads.archive_thread(archived.id, owner.id)

      assert Enum.map(ChatThreads.list_threads(channel.id), & &1.id) == [active.id]
      assert Enum.map(ChatThreads.list_threads(channel.id, :archived), & &1.id) == [archived.id]

      all_ids = ChatThreads.list_threads(channel.id, :all) |> Enum.map(& &1.id) |> Enum.sort()
      assert all_ids == Enum.sort([active.id, archived.id])
    end
  end

  describe "thread messages" do
    test "thread messages are excluded from the main timeline but listed in the thread" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()

      root = create_message!(channel.id, member.id, "root message")
      {:ok, thread} = ChatThreads.create_thread_from_message(root.id, owner.id)

      {:ok, reply_one} = ChatThreads.create_thread_message(thread.id, member.id, "first reply")
      {:ok, reply_two} = ChatThreads.create_thread_message(thread.id, owner.id, "second reply")
      plain = create_message!(channel.id, member.id, "regular timeline message")

      assert reply_one.thread_id == thread.id

      timeline_ids =
        Messaging.get_chat_messages(channel.id, user_id: member.id) |> Enum.map(& &1.id)

      # The root message stays in the timeline; thread replies do not.
      assert root.id in timeline_ids
      assert plain.id in timeline_ids
      refute reply_one.id in timeline_ids
      refute reply_two.id in timeline_ids

      paginated = Messaging.get_conversation_messages(channel.id, member.id)
      paginated_ids = Enum.map(paginated.messages, & &1.id)
      refute reply_one.id in paginated_ids
      assert root.id in paginated_ids

      assert Enum.map(ChatThreads.list_thread_messages(thread.id), & &1.id) ==
               [reply_one.id, reply_two.id]
    end

    test "thread messages bump message_count and last_activity_at" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()
      {:ok, thread} = ChatThreads.create_thread(channel.id, owner.id, %{title: "counters"})

      before_activity = thread.last_activity_at

      {:ok, message} = ChatThreads.create_thread_message(thread.id, member.id, "bump")

      updated = ChatThreads.get_thread(thread.id)
      assert updated.message_count == 1
      assert DateTime.compare(updated.last_activity_at, before_activity) in [:gt, :eq]

      assert DateTime.compare(
               updated.last_activity_at,
               DateTime.from_naive!(message.inserted_at, "Etc/UTC") |> DateTime.truncate(:second)
             ) == :eq
    end

    test "thread messages broadcast as new_thread_message, not new_chat_message" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()
      {:ok, thread} = ChatThreads.create_thread(channel.id, owner.id, %{title: "broadcasts"})

      Phoenix.PubSub.subscribe(Elektrine.PubSub, "chat:#{channel.id}")

      {:ok, message} = ChatThreads.create_thread_message(thread.id, member.id, "hello thread")

      message_id = message.id
      assert_receive {:new_thread_message, %ChatMessage{id: ^message_id}}
      refute_receive {:new_chat_message, %ChatMessage{id: ^message_id}}, 100
    end

    test "archived threads reject new messages" do
      %{owner: owner, member: member, channel: channel} = create_server_channel_with_member()
      {:ok, thread} = ChatThreads.create_thread(channel.id, owner.id, %{title: "closed"})
      {:ok, _} = ChatThreads.archive_thread(thread.id, owner.id)

      assert {:error, :thread_archived} =
               ChatThreads.create_thread_message(thread.id, member.id, "too late")
    end

    test "unknown threads return not_found" do
      %{member: member} = create_server_channel_with_member()

      assert {:error, :not_found} = ChatThreads.create_thread_message(-1, member.id, "nope")
    end
  end
end
