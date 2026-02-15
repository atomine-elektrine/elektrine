defmodule Elektrine.IMAP.HelpersTest do
  use ExUnit.Case, async: true

  alias Elektrine.IMAP.Helpers

  test "get_messages_by_sequence/2 handles ranges, lists, and wildcards" do
    messages = Enum.map(1..5, fn id -> %{id: id} end)

    result = Helpers.get_messages_by_sequence(messages, "1,3:4")
    assert Enum.map(result, fn {_msg, seq} -> seq end) == [1, 3, 4]

    reversed_range = Helpers.get_messages_by_sequence(messages, "4:2")
    assert Enum.map(reversed_range, fn {_msg, seq} -> seq end) == [2, 3, 4]

    wildcard = Helpers.get_messages_by_sequence(messages, "*")
    assert Enum.map(wildcard, fn {_msg, seq} -> seq end) == [5]

    full_range = Helpers.get_messages_by_sequence(messages, "1:*")
    assert Enum.map(full_range, fn {_msg, seq} -> seq end) == [1, 2, 3, 4, 5]
  end

  test "matches_search_criteria?/4 evaluates sequence-set criteria correctly" do
    assert Helpers.matches_search_criteria?(%{}, "2:4,7", 3, 10)
    refute Helpers.matches_search_criteria?(%{}, "2:4,7", 6, 10)

    assert Helpers.matches_search_criteria?(%{}, "1:*", 10, 10)
    refute Helpers.matches_search_criteria?(%{}, "1:*", 10, 9)

    refute Helpers.matches_search_criteria?(%{}, "NOT 2:4", 3, 10)
    assert Helpers.matches_search_criteria?(%{}, "NOT 2:4", 8, 10)
  end
end
