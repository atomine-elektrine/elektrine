defmodule Elektrine.Email.AliasTest do
  use Elektrine.DataCase

  alias Elektrine.Email.Alias

  describe "changeset/2" do
    test "with valid attributes" do
      attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: 1,
        enabled: true,
        description: "Test alias"
      }

      changeset = Alias.changeset(%Alias{}, attrs)

      assert changeset.valid?
    end

    test "requires alias_email and user_id" do
      changeset = Alias.changeset(%Alias{}, %{})

      assert %{alias_email: ["can't be blank"]} = errors_on(changeset)
      assert %{user_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email format for alias_email" do
      attrs = %{
        alias_email: "invalid-email",
        target_email: "user@example.com",
        user_id: 1
      }

      changeset = Alias.changeset(%Alias{}, attrs)

      assert %{alias_email: ["must be a valid email format"]} = errors_on(changeset)
    end

    test "validates email format for target_email" do
      attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "invalid-email",
        user_id: 1
      }

      changeset = Alias.changeset(%Alias{}, attrs)

      assert %{target_email: ["must be a valid email format"]} = errors_on(changeset)
    end

    test "prevents alias_email and target_email from being the same" do
      attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "tester@elektrine.com",
        user_id: 1
      }

      changeset = Alias.changeset(%Alias{}, attrs)

      errors = errors_on(changeset)
      assert "cannot be the same as the alias email" in errors.target_email
    end

    test "validates length constraints" do
      # Test local part max length (30 chars) - will trigger before overall 255 limit
      attrs = %{
        alias_email: String.duplicate("a", 50) <> "@elektrine.com",
        target_email: String.duplicate("b", 250) <> "@example.com",
        description: String.duplicate("c", 501),
        user_id: 1
      }

      changeset = Alias.changeset(%Alias{}, attrs)
      errors = errors_on(changeset)

      assert Enum.any?(errors.alias_email, &String.contains?(&1, "at most 30 characters"))
      assert %{target_email: ["should be at most 255 character(s)"]} = errors
      assert %{description: ["should be at most 500 character(s)"]} = errors
    end

    test "allows alias without target_email" do
      attrs = %{
        alias_email: "tester@elektrine.com",
        user_id: 1,
        enabled: true,
        description: "Test alias without forwarding"
      }

      changeset = Alias.changeset(%Alias{}, attrs)

      assert changeset.valid?
    end

    test "allows alias with empty target_email" do
      attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "",
        user_id: 1,
        enabled: true
      }

      changeset = Alias.changeset(%Alias{}, attrs)

      assert changeset.valid?
    end

    test "validates allowed domains for alias_email" do
      # Valid domains
      for domain <- ["elektrine.com", "z.org"] do
        attrs = %{
          alias_email: "tester@#{domain}",
          user_id: 1
        }

        changeset = Alias.changeset(%Alias{}, attrs)
        assert changeset.valid?, "#{domain} should be a valid domain"
      end
    end

    test "rejects invalid domains for alias_email" do
      invalid_domains = ["gmail.com", "example.com", "mydomain.org", "test.net"]

      for domain <- invalid_domains do
        attrs = %{
          alias_email: "tester@#{domain}",
          user_id: 1
        }

        changeset = Alias.changeset(%Alias{}, attrs)
        refute changeset.valid?, "#{domain} should be rejected"
        errors = errors_on(changeset)

        assert Enum.any?(
                 errors.alias_email,
                 &String.contains?(&1, "must use one of the allowed domains")
               )
      end
    end

    test "domain validation is case insensitive" do
      # Mixed case domains should work
      for domain <- ["ELEKTRINE.COM", "Z.ORG", "Elektrine.Com", "z.Org"] do
        attrs = %{
          alias_email: "tester@#{domain}",
          user_id: 1
        }

        changeset = Alias.changeset(%Alias{}, attrs)
        assert changeset.valid?, "#{domain} should be valid (case insensitive)"
      end
    end

    test "validates minimum length for alias local part" do
      # Test usernames that are too short (less than 4 characters)
      # Use unique names to avoid conflicts with any existing test users
      short_usernames = ["x", "xy", "xyz"]

      for short_name <- short_usernames do
        attrs = %{
          alias_email: "#{short_name}@elektrine.com",
          user_id: 1
        }

        changeset = Alias.changeset(%Alias{}, attrs)
        refute changeset.valid?, "#{short_name} should be rejected (too short)"
        errors = errors_on(changeset)

        assert Enum.any?(
                 errors.alias_email,
                 &String.contains?(&1, "must have at least 4 characters before the @ symbol")
               )
      end

      # Test that 4+ character usernames work
      # Use names that are unlikely to conflict with existing test data
      valid_usernames = ["valid4", "testing123", "longusername"]

      for valid_name <- valid_usernames do
        attrs = %{
          alias_email: "#{valid_name}@elektrine.com",
          user_id: 1
        }

        changeset = Alias.changeset(%Alias{}, attrs)
        assert changeset.valid?, "#{valid_name} should be valid (4+ characters)"
      end

      # Test that exactly 4 character usernames work (not reserved words)
      four_char_name = "abcd"

      attrs = %{
        alias_email: "#{four_char_name}@elektrine.com",
        user_id: 1
      }

      changeset = Alias.changeset(%Alias{}, attrs)
      assert changeset.valid?, "#{four_char_name} should be valid (exactly 4 characters)"
    end
  end
end
