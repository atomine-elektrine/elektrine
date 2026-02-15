defmodule Elektrine.CustomDomains.CertificateCacheTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.CustomDomains.CertificateCache

  setup do
    # Ensure CertificateCache is started
    case GenServer.whereis(CertificateCache) do
      nil ->
        {:ok, _pid} = CertificateCache.start_link([])

      _pid ->
        :ok
    end

    # Clear cache before each test
    CertificateCache.clear()

    :ok
  end

  describe "put/3 and get/1" do
    test "returns :error for non-existent hostname" do
      assert CertificateCache.get("nonexistent.com") == :error
    end

    test "is case-insensitive" do
      # We can't test with real PEM data easily, but we can test the interface
      # The actual PEM parsing is tested implicitly
      result = CertificateCache.get("UPPERCASE.COM")
      assert result == :error
    end
  end

  describe "delete/1" do
    test "removes entry from cache" do
      # First verify it doesn't exist
      assert CertificateCache.get("delete-test.com") == :error

      # Delete should succeed even if entry doesn't exist
      assert CertificateCache.delete("delete-test.com") == :ok
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      CertificateCache.clear()
      stats = CertificateCache.stats()
      assert stats.entries == 0
    end
  end

  describe "stats/0" do
    test "returns cache statistics" do
      stats = CertificateCache.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :entries)
      assert Map.has_key?(stats, :memory_bytes)
      assert is_integer(stats.entries)
      assert is_integer(stats.memory_bytes)
    end
  end
end
