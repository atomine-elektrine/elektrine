defmodule Elektrine.EmailAliasTest do
  use Elektrine.DataCase

  alias Elektrine.Accounts
  alias Elektrine.Email
  alias Elektrine.Email.Alias

  describe "email aliases" do
    setup do
      {:ok, user} =
        Accounts.create_user(%{
          username: "testuser",
          password: "password123",
          password_confirmation: "password123"
        })

      %{user: user}
    end

    test "list_aliases/1 returns all aliases for a user", %{user: user} do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      aliases = Email.list_aliases(user.id)
      assert length(aliases) == 1
      assert hd(aliases).alias_email == "tester@elektrine.com"
    end

    test "get_alias/2 returns alias for specific user", %{user: user} do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id
      }

      {:ok, alias} = Email.create_alias(alias_attrs)

      found_alias = Email.get_alias(alias.id, user.id)
      assert found_alias.id == alias.id
      assert found_alias.alias_email == "tester@elektrine.com"
    end

    test "get_alias/2 returns nil for wrong user", %{user: user} do
      {:ok, other_user} =
        Accounts.create_user(%{
          username: "otheruser",
          password: "password123",
          password_confirmation: "password123"
        })

      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id
      }

      {:ok, alias} = Email.create_alias(alias_attrs)

      found_alias = Email.get_alias(alias.id, other_user.id)
      assert found_alias == nil
    end

    test "get_alias_by_email/1 returns enabled alias", %{user: user} do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id,
        enabled: true
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      found_alias = Email.get_alias_by_email("tester@elektrine.com")
      assert found_alias.alias_email == "tester@elektrine.com"
    end

    test "get_alias_by_email/1 returns alias for disabled alias (does not filter by enabled)", %{
      user: user
    } do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id,
        enabled: false
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      found_alias = Email.get_alias_by_email("tester@elektrine.com")
      assert found_alias.alias_email == "tester@elektrine.com"
      assert found_alias.enabled == false
    end

    test "create_alias/1 creates an alias with valid data", %{user: user} do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id,
        description: "Test alias"
      }

      assert {:ok, alias} = Email.create_alias(alias_attrs)
      assert alias.alias_email == "tester@elektrine.com"
      assert alias.target_email == "user@example.com"
      assert alias.user_id == user.id
      assert alias.enabled == true
      assert alias.description == "Test alias"
    end

    test "create_alias/1 returns error changeset with invalid data" do
      assert {:error, %Ecto.Changeset{}} = Email.create_alias(%{})
    end

    test "legacy dual-domain alias creation is atomic", %{user: user} do
      username = "dualtx#{System.unique_integer([:positive])}"

      {:ok, _existing} =
        Email.create_alias(%{
          alias_email: "#{username}@z.org",
          target_email: "existing@example.com",
          user_id: user.id
        })

      assert {:error, %Ecto.Changeset{}} =
               Email.create_alias(%{
                 username: username,
                 user_id: user.id,
                 target_email: "new@example.com"
               })

      assert Email.get_alias_by_email("#{username}@elektrine.com") == nil
      assert %Alias{} = Email.get_alias_by_email("#{username}@z.org")
    end

    test "update_alias/2 updates alias with valid data", %{user: user} do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id
      }

      {:ok, alias} = Email.create_alias(alias_attrs)

      update_attrs = %{
        target_email: "updated@example.com",
        description: "Updated description",
        enabled: false
      }

      assert {:ok, updated_alias} = Email.update_alias(alias, update_attrs)
      assert updated_alias.target_email == "updated@example.com"
      assert updated_alias.description == "Updated description"
      assert updated_alias.enabled == false
    end

    test "update_alias/2 returns error changeset with invalid data", %{user: user} do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id
      }

      {:ok, alias} = Email.create_alias(alias_attrs)

      assert {:error, %Ecto.Changeset{}} = Email.update_alias(alias, %{target_email: "invalid"})
    end

    test "delete_alias/1 deletes the alias", %{user: user} do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id
      }

      {:ok, alias} = Email.create_alias(alias_attrs)

      assert {:ok, %Alias{}} = Email.delete_alias(alias)
      assert Email.get_alias(alias.id, user.id) == nil
    end

    test "change_alias/1 returns an alias changeset", %{user: user} do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id
      }

      {:ok, alias} = Email.create_alias(alias_attrs)

      assert %Ecto.Changeset{} = Email.change_alias(alias)
    end

    test "resolve_alias/1 returns target email for alias", %{user: user} do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id,
        enabled: true
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      assert Email.resolve_alias("tester@elektrine.com") == "user@example.com"
    end

    test "resolve_alias/1 returns nil for non-existent alias" do
      assert Email.resolve_alias("nonexistent@elektrine.com") == nil
    end

    test "resolve_alias/1 returns :no_forward for disabled alias", %{user: user} do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id,
        enabled: false
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      assert Email.resolve_alias("tester@elektrine.com") == :no_forward
    end

    test "resolve_alias/1 returns :no_forward for alias without target", %{user: user} do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        user_id: user.id,
        enabled: true
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      assert Email.resolve_alias("tester@elektrine.com") == :no_forward
    end

    test "resolve_alias/1 returns :no_forward for alias with empty target", %{user: user} do
      alias_attrs = %{
        alias_email: "tester@elektrine.com",
        target_email: "",
        user_id: user.id,
        enabled: true
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      assert Email.resolve_alias("tester@elektrine.com") == :no_forward
    end

    test "create_alias/1 fails with invalid domain", %{user: user} do
      alias_attrs = %{
        alias_email: "test@gmail.com",
        target_email: "user@example.com",
        user_id: user.id
      }

      assert {:error, changeset} = Email.create_alias(alias_attrs)
      errors = errors_on(changeset)

      assert Enum.any?(
               errors.alias_email,
               &String.contains?(&1, "must use one of the allowed domains")
             )
    end

    test "create_alias/1 succeeds with allowed domains", %{user: user} do
      # Test elektrine.com
      alias_attrs_1 = %{
        alias_email: "test1@elektrine.com",
        target_email: "user@example.com",
        user_id: user.id
      }

      assert {:ok, _alias} = Email.create_alias(alias_attrs_1)

      # Test z.org
      alias_attrs_2 = %{
        alias_email: "test2@z.org",
        target_email: "user@example.com",
        user_id: user.id
      }

      assert {:ok, _alias} = Email.create_alias(alias_attrs_2)
    end

    test "create_alias/1 prevents duplicate aliases across users", %{user: user} do
      {:ok, other_user} =
        Accounts.create_user(%{
          username: "otheruser",
          password: "password123",
          password_confirmation: "password123"
        })

      # Create alias for first user
      alias_attrs = %{
        alias_email: "shared@elektrine.com",
        target_email: "user1@example.com",
        user_id: user.id
      }

      assert {:ok, _alias} = Email.create_alias(alias_attrs)

      # Try to create same alias for second user
      alias_attrs_2 = %{
        alias_email: "shared@elektrine.com",
        target_email: "user2@example.com",
        user_id: other_user.id
      }

      assert {:error, changeset} = Email.create_alias(alias_attrs_2)
      errors = errors_on(changeset)
      assert Enum.any?(errors.alias_email, &String.contains?(&1, "alias"))
    end

    test "create_alias/1 prevents aliases that conflict with existing mailboxes", %{user: user} do
      # Get the user's existing mailbox (created during user creation)
      mailbox = Email.get_user_mailbox(user.id)

      # Try to create an alias using the same email as the mailbox
      alias_attrs = %{
        alias_email: mailbox.email,
        target_email: "user@example.com",
        user_id: user.id
      }

      assert {:error, changeset} = Email.create_alias(alias_attrs)

      assert %{alias_email: ["this email address is already in use as a mailbox"]} =
               errors_on(changeset)
    end
  end
end
