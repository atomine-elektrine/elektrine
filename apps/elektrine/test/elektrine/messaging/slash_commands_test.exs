defmodule Elektrine.Messaging.SlashCommandsTest do
  use ExUnit.Case, async: true

  alias Elektrine.Messaging.SlashCommands

  describe "process/2" do
    test "passes through regular messages" do
      assert {:send, "hello world"} = SlashCommands.process("hello world")
    end

    test "returns help text for /help" do
      assert {:noop, message} = SlashCommands.process("/help")
      assert message =~ "/giphy"
      assert message =~ "/invite"
    end

    test "formats /me using handle when present" do
      assert {:send, "*alice_waves hello*"} =
               SlashCommands.process("/me hello",
                 user_handle: "alice_waves",
                 username: "alice"
               )
    end

    test "formats /shrug with optional prefix text" do
      assert {:send, "¯\\_(ツ)_/¯"} = SlashCommands.process("/shrug")
      assert {:send, "fine ¯\\_(ツ)_/¯"} = SlashCommands.process("/shrug fine")
    end

    test "resolves /giphy through injected search function" do
      search_fn = fn "cats", _opts -> {:ok, [%{url: "https://giphy.test/cat.gif"}]} end

      assert {:send, "https://giphy.test/cat.gif"} =
               SlashCommands.process("/giphy cats", giphy_search_fun: search_fn)
    end

    test "builds invite links with conversation hash" do
      conversation = %{id: 42, hash: "abc123"}

      assert {:send, "https://z.org/chat/join/abc123"} =
               SlashCommands.process("/invite",
                 endpoint_url: "https://z.org",
                 conversation: conversation
               )
    end

    test "returns error for unknown slash command" do
      assert {:error, message} = SlashCommands.process("/doesnotexist")
      assert message =~ "Unknown command"
    end
  end
end
