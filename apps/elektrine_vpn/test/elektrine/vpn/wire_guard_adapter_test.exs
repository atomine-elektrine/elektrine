defmodule Elektrine.VPN.WireGuardAdapterTest do
  use ExUnit.Case, async: true

  alias Elektrine.VPN.WireGuardAdapter

  test "parse_dump/1 parses peer counters and handshakes" do
    dump = """
    priv pub 51820 off
    peer-a	(none)	198.51.100.10:443	10.8.0.2/32	1712345678	1234	5678	25
    peer-b	(none)	(none)	10.8.0.3/32	0	0	0	25
    """

    assert [first, second] = WireGuardAdapter.parse_dump(dump)

    assert first.public_key == "peer-a"
    assert first.bytes_received == 1234
    assert first.bytes_sent == 5678
    assert first.last_handshake == "2024-04-05T19:34:38Z"

    assert second.public_key == "peer-b"
    assert second.last_handshake == nil
    assert second.bytes_received == 0
    assert second.bytes_sent == 0
  end
end
