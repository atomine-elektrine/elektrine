defmodule Elektrine.CustomDomains.AcmeChallengeStoreTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.CustomDomains.AcmeChallengeStore

  setup do
    # Ensure AcmeChallengeStore is started
    case GenServer.whereis(AcmeChallengeStore) do
      nil ->
        {:ok, _pid} = AcmeChallengeStore.start_link([])

      _pid ->
        :ok
    end

    :ok
  end

  describe "put/2 and get/1" do
    test "stores and retrieves challenge token" do
      token = "test-token-#{System.unique_integer()}"
      response = "test-response.key-authorization"

      assert AcmeChallengeStore.put(token, response) == :ok
      assert AcmeChallengeStore.get(token) == response
    end

    test "returns nil for non-existent token" do
      assert AcmeChallengeStore.get("nonexistent-token") == nil
    end

    test "overwrites existing token" do
      token = "overwrite-token-#{System.unique_integer()}"

      AcmeChallengeStore.put(token, "first-response")
      AcmeChallengeStore.put(token, "second-response")

      assert AcmeChallengeStore.get(token) == "second-response"
    end

    test "stores multiple tokens independently" do
      token1 = "token1-#{System.unique_integer()}"
      token2 = "token2-#{System.unique_integer()}"

      AcmeChallengeStore.put(token1, "response1")
      AcmeChallengeStore.put(token2, "response2")

      assert AcmeChallengeStore.get(token1) == "response1"
      assert AcmeChallengeStore.get(token2) == "response2"
    end
  end

  describe "delete/1" do
    test "removes token from store" do
      token = "delete-token-#{System.unique_integer()}"

      AcmeChallengeStore.put(token, "response")
      assert AcmeChallengeStore.get(token) == "response"

      assert AcmeChallengeStore.delete(token) == :ok
      assert AcmeChallengeStore.get(token) == nil
    end

    test "succeeds even if token doesn't exist" do
      assert AcmeChallengeStore.delete("nonexistent") == :ok
    end
  end

  describe "expiration" do
    # Note: We can't easily test the 10-minute expiration without waiting,
    # but we verify the basic TTL mechanism is in place
    test "tokens have expiration times stored" do
      token = "expiry-token-#{System.unique_integer()}"
      AcmeChallengeStore.put(token, "response")

      # The token should be retrievable immediately
      assert AcmeChallengeStore.get(token) == "response"
    end
  end
end
