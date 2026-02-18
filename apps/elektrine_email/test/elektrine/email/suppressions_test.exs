defmodule Elektrine.Email.SuppressionsTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.Email.Suppressions

  describe "suppress_recipient/3" do
    test "upserts suppression entries for the same recipient" do
      user = user_fixture()

      assert {:ok, suppression} =
               Suppressions.suppress_recipient(user.id, "Blocked@Example.com",
                 reason: "hard_bounce",
                 source: "test"
               )

      assert suppression.email == "blocked@example.com"
      assert suppression.reason == "hard_bounce"
      assert Suppressions.suppressed?(user.id, "blocked@example.com")

      assert {:ok, updated} =
               Suppressions.suppress_recipient(user.id, "blocked@example.com",
                 reason: "complaint",
                 source: "test"
               )

      assert updated.id == suppression.id
      assert updated.reason == "complaint"
      assert length(Suppressions.list_active_suppressions(user.id)) == 1
    end

    test "ignores expired suppressions when checking active status" do
      user = user_fixture()
      expires_at = DateTime.utc_now() |> DateTime.add(-60, :second)

      assert {:ok, _suppression} =
               Suppressions.suppress_recipient(user.id, "expired@example.com",
                 reason: "hard_bounce",
                 source: "test",
                 expires_at: expires_at
               )

      refute Suppressions.suppressed?(user.id, "expired@example.com")
      assert Suppressions.get_active_suppression(user.id, "expired@example.com") == nil
    end
  end

  describe "filter_suppressed_recipients/3" do
    test "filters only suppressed external recipients by default" do
      user = user_fixture()

      assert {:ok, _suppression} =
               Suppressions.suppress_recipient(user.id, "blocked@example.com",
                 reason: "hard_bounce",
                 source: "test"
               )

      result =
        Suppressions.filter_suppressed_recipients(user.id, [
          "blocked@example.com",
          "friend@elektrine.com"
        ])

      assert result.suppressed == ["blocked@example.com"]
      assert result.allowed == ["friend@elektrine.com"]
      assert result.reasons["blocked@example.com"] == "hard_bounce"
    end
  end
end
