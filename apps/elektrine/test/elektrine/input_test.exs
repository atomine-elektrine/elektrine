defmodule Elektrine.InputTest do
  use ExUnit.Case, async: true

  alias Elektrine.Input

  test "sanitizes valid email addresses" do
    assert Input.sanitize_email("  max@example.com ") == "max@example.com"
    assert Input.sanitize_email("not an email") == ""
  end

  test "sanitizes usernames to safe characters" do
    assert Input.sanitize_username("  Max! Field  ") == "Max Field"
  end
end
