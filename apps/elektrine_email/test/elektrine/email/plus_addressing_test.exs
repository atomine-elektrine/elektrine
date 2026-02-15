defmodule Elektrine.Email.PlusAddressingTest do
  use Elektrine.DataCase

  alias Elektrine.Email

  describe "normalize_plus_address/1" do
    test "removes plus addressing from email" do
      assert Email.normalize_plus_address("user+tag@example.com") == "user@example.com"

      assert Email.normalize_plus_address("john.doe+newsletter@company.org") ==
               "john.doe@company.org"

      assert Email.normalize_plus_address("test+multiple+plus@domain.com") == "test@domain.com"
    end

    test "returns original email when no plus addressing present" do
      assert Email.normalize_plus_address("user@example.com") == "user@example.com"
      assert Email.normalize_plus_address("john.doe@company.org") == "john.doe@company.org"
    end

    test "handles edge cases" do
      assert Email.normalize_plus_address("+tag@example.com") == "@example.com"
      assert Email.normalize_plus_address("user+@example.com") == "user@example.com"
      assert Email.normalize_plus_address("") == ""
      assert Email.normalize_plus_address(nil) == nil
    end

    test "handles invalid email formats" do
      assert Email.normalize_plus_address("notanemail") == "notanemail"
      assert Email.normalize_plus_address("user+tag") == "user+tag"
      assert Email.normalize_plus_address("@example.com") == "@example.com"
    end

    test "preserves domain with special characters" do
      assert Email.normalize_plus_address("user+tag@sub.domain.example.com") ==
               "user@sub.domain.example.com"

      assert Email.normalize_plus_address("user+tag@example-company.com") ==
               "user@example-company.com"
    end
  end
end
