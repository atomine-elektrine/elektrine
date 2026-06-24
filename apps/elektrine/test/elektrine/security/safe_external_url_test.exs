defmodule Elektrine.Security.SafeExternalURLTest do
  use ExUnit.Case, async: true

  alias Elektrine.Security.SafeExternalURL

  test "normalizes public http and https URLs" do
    assert {:ok, "https://example.com/path"} =
             SafeExternalURL.normalize(" https://example.com/path ")

    assert {:ok, "http://example.com/path"} = SafeExternalURL.normalize("http://example.com/path")
  end

  test "rejects external redirect URLs with controls, userinfo, and unsafe schemes" do
    assert {:error, :invalid_url} =
             SafeExternalURL.normalize("https://example.com\r\nLocation: https://evil.test")

    assert {:error, :userinfo_not_allowed} =
             SafeExternalURL.normalize("https://example.com@evil.test/path")

    assert {:error, :invalid_url} = SafeExternalURL.normalize("javascript:alert(1)")
    assert {:error, :invalid_url} = SafeExternalURL.normalize("//evil.test/path")
  end
end
