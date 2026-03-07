defmodule Elektrine.Email.CategoryPreferencesTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Email.Categorizer
  alias Elektrine.Email.CategoryPreferences

  describe "learned category preferences" do
    setup do
      user = user_fixture()
      {:ok, user: user}
    end

    test "learns exact sender category from manual move", %{user: user} do
      assert :ok ==
               CategoryPreferences.learn_from_manual_move(
                 user.id,
                 "Billing Team <receipts@shop.example>",
                 "ledger"
               )

      match = CategoryPreferences.match_category(user.id, "Receipts <receipts@shop.example>")

      assert match.category == "ledger"
      assert match.source == "learned_sender"
      assert is_list(match.reasons)
    end

    test "domain preference applies after repeated learning", %{user: user} do
      assert :ok ==
               CategoryPreferences.learn_from_manual_move(
                 user.id,
                 "Billing <receipts@shop.example>",
                 "ledger"
               )

      assert is_nil(CategoryPreferences.match_category(user.id, "alerts@shop.example"))

      assert :ok ==
               CategoryPreferences.learn_from_manual_move(
                 user.id,
                 "Support <support@shop.example>",
                 "ledger"
               )

      match = CategoryPreferences.match_category(user.id, "alerts@shop.example")

      assert match.category == "ledger"
      assert match.source == "learned_domain"
      assert match.learned_count >= 2
    end

    test "categorizer uses learned sender preference and stores source metadata", %{user: user} do
      assert :ok ==
               CategoryPreferences.learn_from_manual_move(
                 user.id,
                 "digest@updates.example.com",
                 "feed"
               )

      message = %{
        "subject" => "Small update",
        "from" => "Digest Bot <digest@updates.example.com>",
        "to" => "user@elektrine.com",
        "text_body" => "Hello there",
        "html_body" => "",
        "metadata" => %{"headers" => %{}}
      }

      result = Categorizer.categorize_message(message, user_id: user.id)
      categorization = get_in(result, ["metadata", "categorization"])

      assert result["category"] == "feed"
      assert categorization["source"] == "learned_sender"
      assert categorization["confidence"] >= 0.8
      assert is_list(categorization["reasons"])
    end
  end
end
