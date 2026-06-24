defmodule Elektrine.Security.URLValidatorTest do
  use ExUnit.Case, async: true

  alias Elektrine.Security.URLValidator

  describe "validate/1" do
    test "trims trailing root dots before host classification" do
      result =
        URLValidator.validate(
          "https://openpgpkey.example.localhost./.well-known/openpgpkey/example.localhost./hu/test"
        )

      assert result in [{:error, :private_domain}, {:error, :private_ip}]
    end
  end

  describe "validate_websocket/2" do
    test "rejects private websocket endpoints" do
      assert {:error, :private_ip} =
               URLValidator.validate_websocket("wss://10.0.0.1/_arblarg/session")

      assert {:error, :private_ip} =
               URLValidator.validate_websocket("wss://[::ffff:127.0.0.1]/_arblarg/session")
    end

    test "rejects plaintext websocket endpoints unless explicitly allowed" do
      assert {:error, :invalid_scheme} =
               URLValidator.validate_websocket("ws://example.com/_arblarg/session")
    end

    test "allows localhost websocket endpoints only when requested" do
      assert {:error, :private_ip} =
               URLValidator.validate_websocket("ws://127.0.0.1:49152/_arblarg/session",
                 allow_insecure_transport: true
               )

      assert :ok =
               URLValidator.validate_websocket("ws://127.0.0.1:49152/_arblarg/session",
                 allow_insecure_transport: true,
                 allow_localhost: true
               )
    end
  end
end
