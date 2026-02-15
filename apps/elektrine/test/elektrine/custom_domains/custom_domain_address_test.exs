defmodule Elektrine.CustomDomains.CustomDomainAddressTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.CustomDomains.CustomDomainAddress

  describe "create_changeset/2" do
    test "validates required fields" do
      changeset = CustomDomainAddress.create_changeset(%CustomDomainAddress{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).local_part
      assert "can't be blank" in errors_on(changeset).custom_domain_id
      assert "can't be blank" in errors_on(changeset).mailbox_id
    end

    test "validates local part format" do
      changeset =
        CustomDomainAddress.create_changeset(%CustomDomainAddress{}, %{
          local_part: "hello.world",
          custom_domain_id: 1,
          mailbox_id: 1
        })

      assert changeset.valid?

      # Invalid: starts with special character
      changeset =
        CustomDomainAddress.create_changeset(%CustomDomainAddress{}, %{
          local_part: ".invalid",
          custom_domain_id: 1,
          mailbox_id: 1
        })

      refute changeset.valid?
    end

    test "normalizes local part to lowercase" do
      changeset =
        CustomDomainAddress.create_changeset(%CustomDomainAddress{}, %{
          local_part: "HELLO",
          custom_domain_id: 1,
          mailbox_id: 1
        })

      assert get_change(changeset, :local_part) == "hello"
    end

    test "rejects reserved local parts" do
      reserved_parts = ~w(postmaster abuse admin administrator hostmaster webmaster)

      for part <- reserved_parts do
        changeset =
          CustomDomainAddress.create_changeset(%CustomDomainAddress{}, %{
            local_part: part,
            custom_domain_id: 1,
            mailbox_id: 1
          })

        refute changeset.valid?, "Expected #{part} to be rejected"
        assert "is a reserved address" in errors_on(changeset).local_part
      end
    end

    test "validates local part length" do
      # Too long
      long_part = String.duplicate("a", 65)

      changeset =
        CustomDomainAddress.create_changeset(%CustomDomainAddress{}, %{
          local_part: long_part,
          custom_domain_id: 1,
          mailbox_id: 1
        })

      refute changeset.valid?
      assert "should be at most 64 character(s)" in errors_on(changeset).local_part
    end

    test "allows description" do
      changeset =
        CustomDomainAddress.create_changeset(%CustomDomainAddress{}, %{
          local_part: "hello",
          custom_domain_id: 1,
          mailbox_id: 1,
          description: "Main contact email"
        })

      assert changeset.valid?
      assert get_change(changeset, :description) == "Main contact email"
    end
  end

  describe "update_changeset/2" do
    test "allows updating enabled status" do
      address = %CustomDomainAddress{
        local_part: "hello",
        custom_domain_id: 1,
        mailbox_id: 1,
        enabled: true
      }

      changeset = CustomDomainAddress.update_changeset(address, %{enabled: false})
      assert changeset.valid?
      assert get_change(changeset, :enabled) == false
    end

    test "allows updating description" do
      address = %CustomDomainAddress{
        local_part: "hello",
        custom_domain_id: 1,
        mailbox_id: 1
      }

      changeset = CustomDomainAddress.update_changeset(address, %{description: "New description"})
      assert changeset.valid?
    end
  end
end
