defmodule Elektrine.CallsTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.AccountsFixtures
  alias Elektrine.Calls
  alias Elektrine.Calls.Call
  alias Elektrine.Friends
  alias Elektrine.Messaging
  alias Elektrine.Messaging.ChatMessage

  describe "initiate_call/4" do
    test "accepts the shared DM conversation between caller and callee" do
      caller = AccountsFixtures.user_fixture()
      callee = AccountsFixtures.user_fixture()

      make_friends(caller.id, callee.id)
      {:ok, conversation} = Messaging.create_dm_conversation(caller.id, callee.id)

      assert {:ok, %Call{} = call} =
               Calls.initiate_call(caller.id, callee.id, "audio", conversation.id)

      assert call.conversation_id == conversation.id
    end

    test "rejects conversation ids that are not a shared DM conversation" do
      caller = AccountsFixtures.user_fixture()
      callee = AccountsFixtures.user_fixture()
      third_user = AccountsFixtures.user_fixture()

      make_friends(caller.id, callee.id)

      {:ok, other_dm} = Messaging.create_dm_conversation(caller.id, third_user.id)

      assert {:error, :invalid_conversation} =
               Calls.initiate_call(caller.id, callee.id, "audio", other_dm.id)

      group =
        case Messaging.create_group_conversation(
               caller.id,
               %{name: "call-validation-#{System.unique_integer([:positive])}"},
               [callee.id]
             ) do
          {:ok, conversation} -> conversation
          {:ok, conversation, _failed_count} -> conversation
        end

      assert {:error, :invalid_conversation} =
               Calls.initiate_call(caller.id, callee.id, "audio", group.id)
    end
  end

  describe "update_call_status/3" do
    test "keeps the first terminal status and call log message" do
      caller = AccountsFixtures.user_fixture()
      callee = AccountsFixtures.user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(caller.id, callee.id)

      call = insert_call(caller.id, callee.id, conversation.id, "ringing")

      assert {:ok, %{status: "rejected"}} = Calls.reject_call(call.id)
      assert {:ok, %{status: "rejected"}} = Calls.end_call(call.id)
      assert %Call{status: "rejected"} = Calls.get_call(call.id)

      call_logs =
        from(m in ChatMessage,
          where: m.conversation_id == ^conversation.id and m.message_type == "system",
          where: fragment("?->>'call_id' = ?", m.media_metadata, ^to_string(call.id))
        )
        |> Repo.all()

      assert length(call_logs) == 1
      assert hd(call_logs).content == "Audio call declined"
    end

    test "does not regress an active call back to ringing" do
      caller = AccountsFixtures.user_fixture()
      callee = AccountsFixtures.user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(caller.id, callee.id)

      call =
        insert_call(caller.id, callee.id, conversation.id, "active", %{
          started_at: DateTime.add(DateTime.utc_now(), -10, :second)
        })

      initial_updated_at = call.updated_at

      assert {:ok, %Call{status: "active"} = unchanged} =
               Calls.update_call_status(call.id, "ringing")

      assert unchanged.updated_at == initial_updated_at
    end

    test "updates updated_at when transition is applied" do
      caller = AccountsFixtures.user_fixture()
      callee = AccountsFixtures.user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(caller.id, callee.id)
      call = insert_call(caller.id, callee.id, conversation.id, "initiated")

      Process.sleep(1100)

      assert {:ok, %Call{status: "ringing"} = updated} =
               Calls.update_call_status(call.id, "ringing")

      refute updated.updated_at == call.updated_at
    end

    test "broadcasts call_ended to both participants when ending a call" do
      caller = AccountsFixtures.user_fixture()
      callee = AccountsFixtures.user_fixture()
      {:ok, conversation} = Messaging.create_dm_conversation(caller.id, callee.id)

      call =
        insert_call(caller.id, callee.id, conversation.id, "active", %{
          started_at: DateTime.add(DateTime.utc_now(), -15, :second)
        })

      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{caller.id}")
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{callee.id}")

      assert {:ok, %Call{status: "ended"}} = Calls.end_call(call.id)
      call_id = call.id
      assert_receive {:call_ended, %Call{id: ^call_id, status: "ended"}}
      assert_receive {:call_ended, %Call{id: ^call_id, status: "ended"}}
    end
  end

  defp insert_call(caller_id, callee_id, conversation_id, status, extra_attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          caller_id: caller_id,
          callee_id: callee_id,
          conversation_id: conversation_id,
          call_type: "audio",
          status: status
        },
        extra_attrs
      )

    %Call{}
    |> Call.changeset(attrs)
    |> Repo.insert!()
  end

  defp make_friends(user1_id, user2_id) do
    {:ok, request} = Friends.send_friend_request(user1_id, user2_id)
    {:ok, _friendship} = Friends.accept_friend_request(request.id, user2_id)
    :ok
  end
end
