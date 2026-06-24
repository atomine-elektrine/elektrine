defmodule Elektrine.Messaging.Federation.ConfigTest do
  use ExUnit.Case, async: true

  alias Elektrine.Messaging.Federation.Config

  describe "outbound_session_websocket_url/2" do
    test "rejects explicit private websocket endpoints" do
      peer = %{
        session_websocket_endpoint: "wss://10.0.0.1/_arblarg/session",
        base_url: "https://remote.example"
      }

      assert Config.outbound_session_websocket_url(peer, false) == nil
    end

    test "rejects private websocket endpoints derived from base_url" do
      peer = %{base_url: "https://10.0.0.1"}

      assert Config.outbound_session_websocket_url(peer, false) == nil
    end

    test "does not allow plaintext websocket endpoints unless insecure transport is enabled" do
      peer = %{session_websocket_endpoint: "ws://127.0.0.1:49152/_arblarg/session"}

      assert Config.outbound_session_websocket_url(peer, false) == nil
      assert Config.outbound_session_websocket_url(peer, true) == peer.session_websocket_endpoint
    end
  end
end
