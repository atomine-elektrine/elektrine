defmodule Elektrine.IMAP.CommandsTest do
  use ExUnit.Case, async: true

  alias Elektrine.IMAP.Commands

  test "capability_string/1 advertises only implemented baseline capabilities" do
    unauth = Commands.capability_string(:not_authenticated)
    auth = Commands.capability_string(:authenticated)

    assert unauth =~ "IMAP4rev1"
    assert unauth =~ "AUTH=PLAIN"
    assert unauth =~ "AUTH=LOGIN"
    assert unauth =~ "UIDPLUS"
    assert unauth =~ "IDLE"

    refute unauth =~ "IMAP4rev2"
    refute unauth =~ "QRESYNC"
    refute unauth =~ "CONDSTORE"
    refute unauth =~ "OBJECTID"

    assert auth =~ "IMAP4rev1"
    refute auth =~ "AUTH=PLAIN"
    refute auth =~ "AUTH=LOGIN"
  end
end
