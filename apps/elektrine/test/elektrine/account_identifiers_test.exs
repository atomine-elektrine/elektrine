defmodule Elektrine.AccountIdentifiersTest do
  use ExUnit.Case, async: true

  alias Elektrine.AccountIdentifiers

  test "formats local handles for maps and strings" do
    assert AccountIdentifiers.local_handle(%{handle: "max", username: "other"}) ==
             "max@elektrine.com"

    assert AccountIdentifiers.at_local_handle(%{username: "max"}) == "@max@elektrine.com"
    assert AccountIdentifiers.at_local_handle("max") == "@max@elektrine.com"
  end

  test "formats public contact mailto for local users" do
    assert AccountIdentifiers.public_contact_mailto(%{username: "max"}) ==
             "mailto:max@elektrine.com"
  end
end
