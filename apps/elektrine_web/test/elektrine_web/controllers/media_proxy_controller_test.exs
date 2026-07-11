defmodule ElektrineSocialWeb.MediaProxyControllerTest do
  use ExUnit.Case, async: false

  alias Elektrine.MediaProxy
  alias ElektrineSocialWeb.MediaProxyController

  test "rejects malformed proxy signatures without raising" do
    encoded_url = Base.url_encode64("https://remote.example/image.png", padding: false)

    assert {:error, :invalid_url} = MediaProxy.decode_url("short/#{encoded_url}")
  end

  test "signs extensionless remote thumbnails and rejects private targets" do
    signed = MediaProxy.signed_url("https://images.example/thumbnail?id=42")

    assert is_binary(signed)
    assert signed =~ "/media_proxy/"
    assert is_nil(MediaProxy.signed_url("http://127.0.0.1/private"))
    assert is_nil(MediaProxy.signed_url("https://user:secret@images.example/thumbnail"))
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

  test "purges failed media proxy URLs and can add a runtime ban" do
    url = "https://remote.example/media/#{System.unique_integer([:positive])}.png"

    refute MediaProxy.failed?(url)
    refute MediaProxy.runtime_banned?(url)

    assert {:ok, true} = MediaProxy.mark_failed(url, :not_found)
    assert MediaProxy.failed?(url)

    assert %{invalidated: [^url], banned: [], rejected: []} = MediaProxy.purge([url])
    refute MediaProxy.failed?(url)
    refute MediaProxy.runtime_banned?(url)

    assert %{invalidated: [^url], banned: [^url], rejected: []} =
             MediaProxy.purge([url], ban: true)

    assert MediaProxy.runtime_banned?(url)
    assert MediaProxy.blocklisted?(url)

    state = MediaProxy.cache_state()
    assert Enum.any?(state.bans, &(&1.url == url))

    assert {:ok, true} = MediaProxy.unban(url)
    refute MediaProxy.runtime_banned?(url)
  end

  test "purge rejects malformed or private media proxy URLs" do
    assert %{invalidated: [], banned: [], rejected: rejected} =
             MediaProxy.purge(["notaurl", "http://127.0.0.1/private.png"], ban: true)

    assert "notaurl" in rejected
    assert "http://127.0.0.1/private.png" in rejected
  end
end
