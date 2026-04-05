defmodule ElektrineSocialWeb.MediaProxyControllerTest do
  use ExUnit.Case, async: true

  alias ElektrineSocialWeb.MediaProxyController

  test "does not treat svg content as inline-safe" do
    assert MediaProxyController.inline_safe_content_type?("image/png")
    refute MediaProxyController.inline_safe_content_type?("image/svg+xml")
    refute MediaProxyController.inline_safe_content_type?("application/pdf")
  end
end
