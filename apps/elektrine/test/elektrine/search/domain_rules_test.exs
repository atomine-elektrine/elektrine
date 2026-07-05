defmodule Elektrine.Search.DomainRulesTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Search.DomainRules

  import Elektrine.AccountsFixtures

  setup do
    %{user: user_fixture()}
  end

  describe "set_rule/3 and rules_map/1" do
    test "stores normalized domains", %{user: user} do
      assert {:ok, rule} = DomainRules.set_rule(user, "  WWW.Example.COM. ", "block")
      assert rule.domain == "example.com"
      assert rule.action == :block

      assert DomainRules.rules_map(user.id) == %{"example.com" => :block}
    end

    test "replaces the action for an existing domain", %{user: user} do
      assert {:ok, _rule} = DomainRules.set_rule(user, "example.com", "lower")
      assert {:ok, _rule} = DomainRules.set_rule(user, "example.com", "pin")

      assert DomainRules.rules_map(user.id) == %{"example.com" => :pin}
    end

    test "rejects invalid domains and actions", %{user: user} do
      assert {:error, %Ecto.Changeset{}} = DomainRules.set_rule(user, "not a domain", "block")
      assert {:error, %Ecto.Changeset{}} = DomainRules.set_rule(user, "example.com", "nuke")

      assert {:error, %Ecto.Changeset{}} =
               DomainRules.set_rule(user, "javascript:alert(1)", "block")
    end
  end

  describe "remove_rule/2" do
    test "removes an existing rule", %{user: user} do
      assert {:ok, _rule} = DomainRules.set_rule(user, "example.com", "block")
      assert :ok = DomainRules.remove_rule(user, "Example.com")
      assert DomainRules.rules_map(user.id) == %{}
    end
  end

  describe "apply_rules/2" do
    defp result(url, relevance), do: %{url: url, relevance: relevance, title: url}

    test "returns results unchanged with no rules" do
      results = [result("https://example.com/a", 0.6)]
      assert DomainRules.apply_rules(results, %{}) == results
      assert DomainRules.apply_rules(results, nil) == results
    end

    test "drops blocked domains including subdomains" do
      results = [
        result("https://example.com/a", 0.6),
        result("https://docs.example.com/b", 0.59),
        result("https://other.test/c", 0.58)
      ]

      assert [%{url: "https://other.test/c"}] =
               DomainRules.apply_rules(results, %{"example.com" => :block})
    end

    test "pins, raises, and lowers adjust relevance" do
      results = [
        result("https://pinme.test/", 0.1),
        result("https://raiseme.test/", 0.5),
        result("https://lowerme.test/", 0.5),
        result("https://plain.test/", 0.5)
      ]

      rules = %{"pinme.test" => :pin, "raiseme.test" => :raise, "lowerme.test" => :lower}

      ranked =
        results
        |> DomainRules.apply_rules(rules)
        |> Enum.sort_by(&(-&1.relevance))
        |> Enum.map(& &1.url)

      assert ranked == [
               "https://pinme.test/",
               "https://raiseme.test/",
               "https://plain.test/",
               "https://lowerme.test/"
             ]
    end

    test "matches hosts with a www prefix" do
      results = [result("https://www.example.com/a", 0.6)]
      assert DomainRules.apply_rules(results, %{"example.com" => :block}) == []
    end
  end
end
