defmodule ElektrineWeb.SafeLiveNavigationTest do
  use ExUnit.Case, async: true

  alias ElektrineWeb.SafeLiveNavigation

  test "classifies internal relative paths for push navigation" do
    assert {:internal, "/timeline/post/123?view=full"} =
             SafeLiveNavigation.destination(" /timeline/post/123?view=full ")
  end

  test "classifies validated external http urls for external redirect" do
    assert {:external, "https://example.com/posts/1"} =
             SafeLiveNavigation.destination("https://example.com/posts/1")
  end

  test "rejects scheme-relative and script urls" do
    assert {:error, _} = SafeLiveNavigation.destination("//evil.test/path")
    assert {:error, _} = SafeLiveNavigation.destination("javascript:alert(1)")
  end

  test "rejects urls with control characters" do
    assert {:error, :invalid_url} =
             SafeLiveNavigation.destination("https://example.com\r\nLocation: https://evil.test")
  end

  test "navigates internal paths with push_navigate" do
    socket = SafeLiveNavigation.navigate(%Phoenix.LiveView.Socket{}, "/account")

    assert socket.redirected == {:live, :redirect, %{kind: :push, to: "/account"}}
  end

  test "navigates valid external urls with external redirect" do
    socket = SafeLiveNavigation.navigate(%Phoenix.LiveView.Socket{}, "https://example.com")

    assert socket.redirected == {:redirect, %{external: "https://example.com", status: 302}}
  end

  test "invalid destinations can fall back to an internal path" do
    socket =
      SafeLiveNavigation.navigate(%Phoenix.LiveView.Socket{}, "//evil.test",
        invalid_message: nil,
        invalid_path: "/"
      )

    assert socket.redirected == {:live, :redirect, %{kind: :push, to: "/"}}
  end
end
