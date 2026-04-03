defmodule Elektrine.EmailAliasTest do
  use Elektrine.DataCase

  alias Elektrine.Accounts
  alias Elektrine.Domains
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

    defp local_email(local_part), do: "#{local_part}@#{Domains.primary_email_domain()}"
    defp forward_email(local_part), do: "#{local_part}@example.net"

    test "list_aliases/1 returns all aliases for a user", %{user: user} do
      alias_attrs = %{
        alias_email: local_email("tester"),
        target_email: forward_email("user"),
        user_id: user.id
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      aliases = Email.list_aliases(user.id)
      assert length(aliases) == 1
      assert hd(aliases).alias_email == local_email("tester")
    end

    test "get_alias/2 returns alias for specific user", %{user: user} do
      alias_attrs = %{
        alias_email: local_email("tester"),
        target_email: forward_email("user"),
        user_id: user.id
      }

      {:ok, alias} = Email.create_alias(alias_attrs)

      found_alias = Email.get_alias(alias.id, user.id)
      assert found_alias.id == alias.id
      assert found_alias.alias_email == local_email("tester")
    end

    test "get_alias/2 returns nil for wrong user", %{user: user} do
      {:ok, other_user} =
        Accounts.create_user(%{
          username: "otheruser",
          password: "password123",
          password_confirmation: "password123"
        })

      alias_attrs = %{
        alias_email: local_email("tester"),
        target_email: forward_email("user"),
        user_id: user.id
      }

      {:ok, alias} = Email.create_alias(alias_attrs)

      found_alias = Email.get_alias(alias.id, other_user.id)
      assert found_alias == nil
    end

    test "get_alias_by_email/1 returns enabled alias", %{user: user} do
      alias_attrs = %{
        alias_email: local_email("tester"),
        target_email: forward_email("user"),
        user_id: user.id,
        enabled: true
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      found_alias = Email.get_alias_by_email(local_email("tester"))
      assert found_alias.alias_email == local_email("tester")
    end

    test "get_alias_by_email/1 returns alias for disabled alias (does not filter by enabled)", %{
      user: user
    } do
      alias_attrs = %{
        alias_email: local_email("tester"),
        target_email: forward_email("user"),
        user_id: user.id,
        enabled: false
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      found_alias = Email.get_alias_by_email(local_email("tester"))
      assert found_alias.alias_email == local_email("tester")
      assert found_alias.enabled == false
    end

    test "create_alias/1 creates an alias with valid data", %{user: user} do
      alias_attrs = %{
        alias_email: local_email("tester"),
        target_email: forward_email("user"),
        user_id: user.id,
        description: "Test alias"
      }

      assert {:ok, alias} = Email.create_alias(alias_attrs)
      assert alias.alias_email == local_email("tester")
      assert alias.target_email == forward_email("user")
      assert alias.user_id == user.id
      assert alias.enabled == true
      assert alias.description == "Test alias"
    end

    test "create_alias/1 returns error changeset with invalid data" do
      assert {:error, %Ecto.Changeset{}} = Email.create_alias(%{})
    end

    test "legacy dual-domain alias creation is atomic", %{user: user} do
      username = "dualtx#{System.unique_integer([:positive])}"
      domains = Domains.supported_email_domains()
      [primary_domain | _] = domains
      conflicting_domain = List.last(domains)

      {:ok, _existing} =
        Email.create_alias(%{
          alias_email: "#{username}@#{conflicting_domain}",
          target_email: forward_email("existing"),
          user_id: user.id
        })

      assert {:error, %Ecto.Changeset{}} =
               Email.create_alias(%{
                 username: username,
                 user_id: user.id,
                 target_email: forward_email("new")
               })

      if length(domains) > 1 do
        assert Email.get_alias_by_email("#{username}@#{primary_domain}") == nil
      end

      assert %Alias{} = Email.get_alias_by_email("#{username}@#{conflicting_domain}")
    end

    test "update_alias/2 updates alias with valid data", %{user: user} do
      alias_attrs = %{
        alias_email: local_email("tester"),
        target_email: forward_email("user"),
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
        alias_email: local_email("tester"),
        target_email: forward_email("user"),
        user_id: user.id
      }

      {:ok, alias} = Email.create_alias(alias_attrs)

      assert {:error, %Ecto.Changeset{}} = Email.update_alias(alias, %{target_email: "invalid"})
    end

    test "delete_alias/1 deletes the alias", %{user: user} do
      alias_attrs = %{
        alias_email: local_email("tester"),
        target_email: forward_email("user"),
        user_id: user.id
      }

      {:ok, alias} = Email.create_alias(alias_attrs)

      assert {:ok, %Alias{}} = Email.delete_alias(alias)
      assert Email.get_alias(alias.id, user.id) == nil
    end

    test "change_alias/1 returns an alias changeset", %{user: user} do
      alias_attrs = %{
        alias_email: local_email("tester"),
        target_email: forward_email("user"),
        user_id: user.id
      }

      {:ok, alias} = Email.create_alias(alias_attrs)

      assert %Ecto.Changeset{} = Email.change_alias(alias)
    end

    test "resolve_alias/1 returns target email for alias", %{user: user} do
      alias_attrs = %{
        alias_email: local_email("tester"),
        target_email: forward_email("user"),
        user_id: user.id,
        enabled: true
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      assert Email.resolve_alias(local_email("tester")) == forward_email("user")
    end

    test "resolve_alias/1 returns nil for non-existent alias" do
      assert Email.resolve_alias(local_email("nonexistent")) == nil
    end

    test "resolve_alias/1 returns :no_forward for disabled alias", %{user: user} do
      alias_attrs = %{
        alias_email: local_email("tester"),
        target_email: forward_email("user"),
        user_id: user.id,
        enabled: false
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      assert Email.resolve_alias(local_email("tester")) == :no_forward
    end

    test "resolve_alias/1 returns :no_forward for alias without target", %{user: user} do
      alias_attrs = %{
        alias_email: local_email("tester"),
        user_id: user.id,
        enabled: true
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      assert Email.resolve_alias(local_email("tester")) == :no_forward
    end

    test "resolve_alias/1 returns :no_forward for alias with empty target", %{user: user} do
      alias_attrs = %{
        alias_email: local_email("tester"),
        target_email: "",
        user_id: user.id,
        enabled: true
      }

      {:ok, _alias} = Email.create_alias(alias_attrs)

      assert Email.resolve_alias(local_email("tester")) == :no_forward
    end

    test "create_alias/1 fails with invalid domain", %{user: user} do
      alias_attrs = %{
        alias_email: "test@gmail.com",
        target_email: forward_email("user"),
        user_id: user.id
      }

      assert {:error, changeset} = Email.create_alias(alias_attrs)
      errors = errors_on(changeset)

      assert Enum.any?(
               errors.alias_email,
               &String.contains?(&1, "choose one of your available email domains")
             )
    end

    test "create_alias/1 succeeds with allowed domains", %{user: user} do
      Domains.supported_email_domains()
      |> Enum.with_index(1)
      |> Enum.each(fn {domain, index} ->
        assert {:ok, _alias} =
                 Email.create_alias(%{
                   alias_email: "test#{index}@#{domain}",
                   target_email: forward_email("user"),
                   user_id: user.id
                 })
      end)
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
        alias_email: local_email("shared"),
        target_email: forward_email("user1"),
        user_id: user.id
      }

      assert {:ok, _alias} = Email.create_alias(alias_attrs)

      # Try to create same alias for second user
      alias_attrs_2 = %{
        alias_email: local_email("shared"),
        target_email: forward_email("user2"),
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
        target_email: forward_email("user"),
        user_id: user.id
      }

      assert {:error, changeset} = Email.create_alias(alias_attrs)

      assert %{alias_email: ["that email address is already in use"]} =
               errors_on(changeset)
    end
  end
end
