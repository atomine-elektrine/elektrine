defmodule ElektrineChatWeb.ChatLive.Operations.HelpersTest do
  use ExUnit.Case, async: true

  alias ElektrineChatWeb.ChatLive.Operations.Helpers

  describe "scope_conversations_to_server/2" do
    test "keeps non-channel conversations and only selected server channels" do
      conversations = [
        %{id: 1, type: "dm", server_id: nil},
        %{id: 2, type: "group", server_id: nil},
        %{id: 3, type: "channel", server_id: 10},
        %{id: 4, type: "channel", server_id: 11},
        %{id: 5, type: "channel", server_id: nil}
      ]

      scoped = Helpers.scope_conversations_to_server(conversations, 10)

      assert Enum.map(scoped, & &1.id) == [1, 2, 3, 5]
    end

    test "hides server channels when no server is active" do
      conversations = [
        %{id: 1, type: "dm", server_id: nil},
        %{id: 2, type: "group", server_id: nil},
        %{id: 3, type: "channel", server_id: 10},
        %{id: 4, type: "channel", server_id: 11},
        %{id: 5, type: "channel", server_id: nil}
      ]

      scoped = Helpers.scope_conversations_to_server(conversations, nil)

      assert Enum.map(scoped, & &1.id) == [1, 2, 5]
    end
  end

  describe "dedupe_messages/1" do
    test "keeps the first occurrence of each message id" do
      messages = [
        %{id: 1, content: "first"},
        %{id: 2, content: "second"},
        %{id: 1, content: "duplicate"}
      ]

      assert Helpers.dedupe_messages(messages) == [
               %{id: 1, content: "first"},
               %{id: 2, content: "second"}
             ]
    end
  end
end
