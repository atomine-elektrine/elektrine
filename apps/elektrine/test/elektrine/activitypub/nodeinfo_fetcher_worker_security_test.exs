defmodule Elektrine.ActivityPub.NodeInfoFetcherWorkerSecurityTest do
  use ExUnit.Case, async: true

  alias Elektrine.ActivityPub.NodeInfoFetcherWorker

  describe "normalize_favicon_url/2" do
    test "rejects absolute private network favicon URLs" do
      assert NodeInfoFetcherWorker.normalize_favicon_url(
               "http://127.0.0.1/favicon.ico",
               "example.com"
             ) == nil
    end

    test "rejects protocol-relative private network favicon URLs" do
      assert NodeInfoFetcherWorker.normalize_favicon_url(
               "//169.254.169.254/latest/meta-data/favicon.ico",
               "example.com"
             ) == nil
    end

    test "rejects relative favicon URLs when the instance domain is private" do
      assert NodeInfoFetcherWorker.normalize_favicon_url("/favicon.ico", "localhost") == nil
    end

    test "normalizes safe relative favicon URLs" do
      assert NodeInfoFetcherWorker.normalize_favicon_url("/favicon.ico", "example.com") ==
               "https://example.com/favicon.ico"
    end
  end
end
