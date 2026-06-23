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

  test "matches_search_criteria?/4 handles Gmail-style UID wildcard searches" do
    message = %{id: 42, read: false, deleted: false}

    assert Helpers.matches_search_criteria?(message, "UID 1:*", 1, 1)
    assert Helpers.matches_search_criteria?(message, "UID 1:* UNDELETED", 1, 1)
    assert Helpers.matches_search_criteria?(message, "RETURN (ALL) UID 1:* UNDELETED", 1, 1)
    assert Helpers.matches_search_criteria?(message, "UID 42:* UNSEEN", 1, 1)
    refute Helpers.matches_search_criteria?(message, "UID 43:*", 1, 1)
  end

  test "matches_search_criteria?/4 handles compound and quoted search values" do
    message = %{
      id: 42,
      read: false,
      deleted: false,
      from: "alerts@example.com",
      to: "user@example.com",
      subject: "hello mobile world",
      text_body: "plain text"
    }

    assert Helpers.matches_search_criteria?(message, ~S(SUBJECT "hello mobile" UNSEEN), 1, 1)
    assert Helpers.matches_search_criteria?(message, ~S(OR FROM "alerts" TO "other"), 1, 1)
    refute Helpers.matches_search_criteria?(message, ~S(OR FROM "nobody" TO "other"), 1, 1)
  end

  test "matches_search_criteria?/4 handles nested groups and NOT expressions" do
    message = %{
      id: 42,
      read: false,
      deleted: false,
      from: "alerts@example.com",
      to: "user@example.com",
      subject: "quarterly report",
      text_body: "plain text"
    }

    assert Helpers.matches_search_criteria?(
             message,
             ~S|(OR FROM "alerts" SUBJECT "invoice") (NOT DELETED) UID 1:*|,
             1,
             10
           )

    refute Helpers.matches_search_criteria?(
             message,
             ~S|(OR FROM "nobody" SUBJECT "invoice") (NOT DELETED)|,
             1,
             10
           )

    refute Helpers.matches_search_criteria?(message, ~S|NOT (OR FROM "alerts" SEEN)|, 1, 10)
  end

  test "matches_search_criteria?/4 handles IMAP date criteria" do
    message = %{
      id: 42,
      read: false,
      deleted: false,
      inserted_at: ~U[2026-06-23 12:00:00Z]
    }

    assert Helpers.matches_search_criteria?(message, "ON 23-Jun-2026", 1, 1)
    assert Helpers.matches_search_criteria?(message, "SINCE 23-Jun-2026", 1, 1)
    assert Helpers.matches_search_criteria?(message, "BEFORE 24-Jun-2026", 1, 1)
    assert Helpers.matches_search_criteria?(message, "SENTON 23-Jun-2026", 1, 1)
    assert Helpers.matches_search_criteria?(message, "SENTSINCE 22-Jun-2026", 1, 1)
    assert Helpers.matches_search_criteria?(message, "SENTBEFORE 24-Jun-2026", 1, 1)

    refute Helpers.matches_search_criteria?(message, "ON 22-Jun-2026", 1, 1)
    refute Helpers.matches_search_criteria?(message, "BEFORE 23-Jun-2026", 1, 1)
    refute Helpers.matches_search_criteria?(message, "SINCE 24-Jun-2026", 1, 1)
  end

  test "decode_auth_login_line/1 decodes valid base64 and supports missing padding" do
    assert {:ok, "user@example.com"} = Helpers.decode_auth_login_line("dXNlckBleGFtcGxlLmNvbQ==")
    assert {:ok, "user@example.com"} = Helpers.decode_auth_login_line("dXNlckBleGFtcGxlLmNvbQ")
  end

  test "decode_auth_login_line/1 supports AUTHENTICATE cancellation token" do
    assert {:ok, "*"} = Helpers.decode_auth_login_line("*")
  end

  test "decode_auth_login_line/1 rejects malformed base64" do
    assert :error = Helpers.decode_auth_login_line("not-base64!!!")
  end

  test "decode_auth_plain/1 accepts unpadded base64 credentials" do
    payload = Base.encode64("\u0000alice\u0000secret", padding: false)
    assert {:ok, "alice", "secret"} = Helpers.decode_auth_plain(payload)
  end

  test "decode_auth_plain/1 handles cancellation token" do
    assert {:error, :cancelled} = Helpers.decode_auth_plain("*")
  end

  test "parse_fetch_items/1 preserves Apple Mail header field fetch tokens" do
    fetch_items =
      Helpers.parse_fetch_items(
        "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (DATE FROM SUBJECT TO CC MESSAGE-ID REFERENCES IN-REPLY-TO)])"
      )

    assert "UID" in fetch_items
    assert "FLAGS" in fetch_items
    assert "INTERNALDATE" in fetch_items
    assert "RFC822.SIZE" in fetch_items

    assert "BODY.PEEK[HEADER.FIELDS (DATE FROM SUBJECT TO CC MESSAGE-ID REFERENCES IN-REPLY-TO)]" in fetch_items
  end

  test "parse_fetch_items/1 expands FETCH macros" do
    assert Helpers.parse_fetch_items("FAST") == ["FLAGS", "INTERNALDATE", "RFC822.SIZE"]

    assert Helpers.parse_fetch_items("(ALL)") == [
             "FLAGS",
             "INTERNALDATE",
             "RFC822.SIZE",
             "ENVELOPE"
           ]
  end

  test "should_mark_as_read?/1 handles partial body fetches" do
    assert Helpers.should_mark_as_read?(["BODY[TEXT]<0.100>"])
    refute Helpers.should_mark_as_read?(["BODY.PEEK[TEXT]<0.100>"])
  end

  test "parse_mailbox_arg/1 extracts mailbox name with optional select params" do
    assert {:ok, "INBOX"} = Helpers.parse_mailbox_arg("\"INBOX\" (CONDSTORE)")
    assert {:ok, "INBOX"} = Helpers.parse_mailbox_arg("INBOX")
  end

  test "parse_append_args/1 accepts APPEND with flags and internal date" do
    assert {:ok, "Sent", [], 1234, false} =
             Helpers.parse_append_args(~S|"Sent" (\Seen) "22-Apr-2026 14:30:00 +0000" {1234}|)
  end

  test "canonical_system_folder_name/1 maps common client aliases" do
    assert Helpers.canonical_system_folder_name("Sent Mail") == "Sent"
    assert Helpers.canonical_system_folder_name("Sent Items") == "Sent"
    assert Helpers.canonical_system_folder_name("Junk") == "Spam"
    assert Helpers.canonical_system_folder_name("Deleted Messages") == "Trash"
  end
end
