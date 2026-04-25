defmodule Elektrine.Email.UnsubscribesTest do
  use Elektrine.DataCase

  alias Elektrine.Email.ListTypes
  alias Elektrine.Email.Unsubscribes

  describe "tokens" do
    test "generated unsubscribe tokens carry email and list id" do
      token = Unsubscribes.generate_token("USER@Example.COM", "elektrine-newsletter")

      assert {:ok, info} = Unsubscribes.verify_token(token)
      assert info.email == "user@example.com"
      assert info.list_id == "elektrine-newsletter"
      assert info.token == token
    end
  end

  describe "unsubscribe records" do
    test "global unsubscribe is idempotent" do
      assert {:ok, _} = Unsubscribes.unsubscribe("global@example.com")
      assert {:ok, _} = Unsubscribes.unsubscribe("GLOBAL@example.com")

      assert length(Unsubscribes.list_unsubscribes("global@example.com")) == 1
      assert Unsubscribes.unsubscribed?("global@example.com", "elektrine-newsletter")
    end

    test "list unsubscribe does not unsubscribe other lists" do
      assert {:ok, _} =
               Unsubscribes.unsubscribe("list@example.com", list_id: "elektrine-newsletter")

      assert Unsubscribes.unsubscribed?("list@example.com", "elektrine-newsletter")
      refute Unsubscribes.unsubscribed?("list@example.com", "elektrine-announcements")
    end
  end

  describe "list types" do
    test "optional mailing lists are active and visible to preferences" do
      active_ids = ListTypes.active_lists() |> Enum.map(& &1.id)

      assert "elektrine-newsletter" in active_ids
      assert "elektrine-marketing" in active_ids
      assert Enum.any?(ListTypes.active_lists(), & &1.can_unsubscribe)
    end
  end
end
