defmodule ElektrineChatTest do
  use ExUnit.Case

  test "exposes chat facade functions" do
    functions = ElektrineChat.__info__(:functions)

    assert {:create_dm_conversation, 2} in functions
    assert {:create_chat_text_message, 3} in functions
  end
end
