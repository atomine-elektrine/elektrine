defmodule ElektrineSocialWeb.MediaProxyControllerTest do
  use ExUnit.Case, async: true

  alias Elektrine.MediaProxy
  alias ElektrineSocialWeb.MediaProxyController

  test "rejects malformed proxy signatures without raising" do
    encoded_url = Base.url_encode64("https://remote.example/image.png", padding: false)

    assert {:error, :invalid_url} = MediaProxy.decode_url("short/#{encoded_url}")
  end

  test "does not treat svg content as inline-safe" do
    assert MediaProxyController.inline_safe_content_type?("image/png")
    assert MediaProxyController.inline_safe_content_type?("image/png; charset=utf-8")
    refute MediaProxyController.inline_safe_content_type?("image/svg+xml")
    refute MediaProxyController.inline_safe_content_type?("application/pdf")
  end

  test "does not treat malformed media types as inline-safe" do
    refute MediaProxyController.inline_safe_content_type?("image/png\r\nx-evil: yes")
    refute MediaProxyController.inline_safe_content_type?("video/")
    refute MediaProxyController.inline_safe_content_type?("")
  end
end
