defmodule Elektrine.StringsTest do
  use ExUnit.Case, async: true

  alias Elektrine.Strings

  test "present trims strings and collapses blanks to nil" do
    assert Strings.present("  value  ") == "value"
    assert Strings.present("   ") == nil
    assert Strings.present(nil) == nil
  end

  test "present? returns boolean presence" do
    assert Strings.present?(" value ")
    refute Strings.present?("   ")
    refute Strings.present?(nil)
  end
end
