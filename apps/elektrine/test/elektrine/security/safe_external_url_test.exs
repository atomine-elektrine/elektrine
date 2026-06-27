defmodule Elektrine.Security.SafeExternalURLTest do
  use ExUnit.Case, async: true

  alias Elektrine.Security.SafeExternalURL

  test "normalizes public http and https URLs" do
    assert {:ok, "https://93.184.216.34/path"} =
             SafeExternalURL.normalize(" https://93.184.216.34/path ")

    assert {:ok, "http://93.184.216.34/path"} =
             SafeExternalURL.normalize("http://93.184.216.34/path")
  end

  test "rejects external redirect URLs with controls, userinfo, and unsafe schemes" do
    assert {:error, :invalid_url} =
             SafeExternalURL.normalize("https://example.com\r\nLocation: https://evil.test")

    assert {:error, :userinfo_not_allowed} =
             SafeExternalURL.normalize("https://example.com@evil.test/path")

    assert {:error, :invalid_url} = SafeExternalURL.normalize("javascript:alert(1)")
    assert {:error, :invalid_url} = SafeExternalURL.normalize("//evil.test/path")
  end

  test "normalizes href-only links without requiring DNS resolution" do
    assert {:ok, "https://remote.example/path"} =
             SafeExternalURL.normalize_href(" https://remote.example/path ")

    assert {:error, :invalid_url} =
             SafeExternalURL.normalize_href("https://example.com\r\nx: y")

    assert {:error, :userinfo_not_allowed} =
             SafeExternalURL.normalize_href("https://example.com@evil.test/path")

    assert {:error, :invalid_url} = SafeExternalURL.normalize_href("javascript:alert(1)")
    assert {:error, :invalid_url} = SafeExternalURL.normalize_href("//evil.test/path")
  end
end
