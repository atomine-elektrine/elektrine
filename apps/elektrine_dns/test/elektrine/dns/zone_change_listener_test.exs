defmodule Elektrine.DNS.ZoneChangeListenerTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.DNS.ZoneChangeListener

  test "channel/0 is stable" do
    assert ZoneChangeListener.channel() == "elektrine_dns_zone_changed"
  end

  # Cross-node delivery can't be exercised through the SQL sandbox: pg_notify
  # only fires on transaction commit and the sandbox rolls back. This checks
  # the emit path runs the pg_notify query without raising; end-to-end
  # delivery is verified against the running nameserver.
  test "notify/1 issues the pg_notify query and returns :ok" do
    assert :ok = ZoneChangeListener.notify()
  end
end
