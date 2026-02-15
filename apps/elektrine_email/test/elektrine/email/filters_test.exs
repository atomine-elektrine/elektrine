defmodule Elektrine.Email.FiltersTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Email.Filters
  alias Elektrine.Email.Filter

  describe "filter CRUD operations" do
    setup do
      user = user_fixture()
      {:ok, user: user}
    end

    test "creates filter with valid attributes", %{user: user} do
      attrs = %{
        user_id: user.id,
        name: "Test Filter",
        conditions: %{
          "match_type" => "all",
          "rules" => [
            %{"field" => "from", "operator" => "contains", "value" => "newsletter"}
          ]
        },
        actions: %{"mark_as_read" => true}
      }

      {:ok, filter} = Filters.create_filter(attrs)

      assert filter.name == "Test Filter"
      assert filter.enabled == true
      assert filter.user_id == user.id
    end

    test "fails to create filter without name", %{user: user} do
      attrs = %{
        user_id: user.id,
        conditions: %{
          "match_type" => "all",
          "rules" => [%{"field" => "from", "operator" => "contains", "value" => "test"}]
        },
        actions: %{"mark_as_read" => true}
      }

      {:error, changeset} = Filters.create_filter(attrs)
      assert "can't be blank" in errors_on(changeset).name
    end

    test "fails to create filter without conditions", %{user: user} do
      attrs = %{
        user_id: user.id,
        name: "Test Filter",
        conditions: %{},
        actions: %{"mark_as_read" => true}
      }

      {:error, changeset} = Filters.create_filter(attrs)
      assert errors_on(changeset).conditions != nil
    end

    test "fails to create filter without actions", %{user: user} do
      attrs = %{
        user_id: user.id,
        name: "Test Filter",
        conditions: %{
          "match_type" => "all",
          "rules" => [%{"field" => "from", "operator" => "contains", "value" => "test"}]
        },
        actions: %{}
      }

      {:error, changeset} = Filters.create_filter(attrs)
      assert errors_on(changeset).actions != nil
    end

    test "lists filters for user", %{user: user} do
      create_test_filter(user.id, "Filter A", 1)
      create_test_filter(user.id, "Filter B", 0)

      filters = Filters.list_filters(user.id)

      assert length(filters) == 2
      # Should be ordered by priority (lower first)
      assert hd(filters).name == "Filter B"
    end

    test "lists only enabled filters", %{user: user} do
      {:ok, _} = create_test_filter(user.id, "Enabled", 0)
      {:ok, disabled} = create_test_filter(user.id, "Disabled", 1)
      Filters.update_filter(disabled, %{enabled: false})

      filters = Filters.list_enabled_filters(user.id)

      assert length(filters) == 1
      assert hd(filters).name == "Enabled"
    end

    test "toggles filter enabled status", %{user: user} do
      {:ok, filter} = create_test_filter(user.id, "Test", 0)
      assert filter.enabled == true

      {:ok, toggled} = Filters.toggle_filter(filter)
      assert toggled.enabled == false

      {:ok, toggled_again} = Filters.toggle_filter(toggled)
      assert toggled_again.enabled == true
    end

    test "deletes filter", %{user: user} do
      {:ok, filter} = create_test_filter(user.id, "To Delete", 0)

      {:ok, _} = Filters.delete_filter(filter)

      assert Filters.get_filter(filter.id, user.id) == nil
    end
  end

  describe "filter matching - match types" do
    test "matches with 'all' match type when all rules match" do
      filter = %Filter{
        conditions: %{
          "match_type" => "all",
          "rules" => [
            %{"field" => "from", "operator" => "contains", "value" => "test"},
            %{"field" => "subject", "operator" => "contains", "value" => "hello"}
          ]
        }
      }

      message = %{
        from: "test@example.com",
        subject: "Hello World",
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "does not match with 'all' match type when one rule fails" do
      filter = %Filter{
        conditions: %{
          "match_type" => "all",
          "rules" => [
            %{"field" => "from", "operator" => "contains", "value" => "test"},
            %{"field" => "subject", "operator" => "contains", "value" => "goodbye"}
          ]
        }
      }

      message = %{
        from: "test@example.com",
        subject: "Hello World",
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      refute Filter.matches?(filter, message)
    end

    test "matches with 'any' match type when at least one rule matches" do
      filter = %Filter{
        conditions: %{
          "match_type" => "any",
          "rules" => [
            %{"field" => "from", "operator" => "contains", "value" => "nomatch"},
            %{"field" => "subject", "operator" => "contains", "value" => "hello"}
          ]
        }
      }

      message = %{
        from: "test@example.com",
        subject: "Hello World",
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "does not match with 'any' match type when no rules match" do
      filter = %Filter{
        conditions: %{
          "match_type" => "any",
          "rules" => [
            %{"field" => "from", "operator" => "contains", "value" => "nomatch"},
            %{"field" => "subject", "operator" => "contains", "value" => "nomatch"}
          ]
        }
      }

      message = %{
        from: "test@example.com",
        subject: "Hello World",
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      refute Filter.matches?(filter, message)
    end
  end

  describe "filter matching - operators" do
    test "contains operator - case insensitive" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "subject", "operator" => "contains", "value" => "HELLO"}]
        }
      }

      message = %{
        subject: "hello world",
        from: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "not_contains operator" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "subject", "operator" => "not_contains", "value" => "spam"}]
        }
      }

      message = %{
        subject: "Hello World",
        from: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "equals operator - case insensitive" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "from", "operator" => "equals", "value" => "Test@Example.com"}]
        }
      }

      message = %{
        from: "test@example.com",
        subject: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "not_equals operator" do
      filter = %Filter{
        conditions: %{
          "rules" => [
            %{"field" => "from", "operator" => "not_equals", "value" => "spam@spam.com"}
          ]
        }
      }

      message = %{
        from: "legitimate@example.com",
        subject: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "starts_with operator" do
      filter = %Filter{
        conditions: %{
          "rules" => [
            %{"field" => "subject", "operator" => "starts_with", "value" => "[Newsletter]"}
          ]
        }
      }

      message = %{
        subject: "[Newsletter] Weekly Update",
        from: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "ends_with operator" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "from", "operator" => "ends_with", "value" => "@company.com"}]
        }
      }

      message = %{
        from: "noreply@company.com",
        subject: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "matches_regex operator" do
      filter = %Filter{
        conditions: %{
          "rules" => [
            %{"field" => "subject", "operator" => "matches_regex", "value" => "^\\[\\w+\\]"}
          ]
        }
      }

      message = %{
        subject: "[URGENT] Please respond",
        from: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "matches_regex handles invalid regex gracefully" do
      filter = %Filter{
        conditions: %{
          "rules" => [
            %{"field" => "subject", "operator" => "matches_regex", "value" => "[invalid"}
          ]
        }
      }

      message = %{
        subject: "Test",
        from: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      refute Filter.matches?(filter, message)
    end

    test "greater_than handles invalid numeric values gracefully" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "size", "operator" => "greater_than", "value" => "NaN"}]
        }
      }

      message = %{
        subject: nil,
        from: nil,
        to: nil,
        cc: nil,
        text_body: "small",
        html_body: nil,
        has_attachments: false
      }

      refute Filter.matches?(filter, message)
    end
  end

  describe "filter matching - fields" do
    test "matches on from field" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "from", "operator" => "contains", "value" => "sender"}]
        }
      }

      message = %{
        from: "sender@example.com",
        to: nil,
        cc: nil,
        subject: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "matches on to field" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "to", "operator" => "contains", "value" => "recipient"}]
        }
      }

      message = %{
        to: "recipient@example.com",
        from: nil,
        cc: nil,
        subject: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "matches on cc field" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "cc", "operator" => "contains", "value" => "manager"}]
        }
      }

      message = %{
        cc: "manager@company.com",
        from: nil,
        to: nil,
        subject: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "matches on body field - text_body" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "body", "operator" => "contains", "value" => "important"}]
        }
      }

      message = %{
        text_body: "This is important information",
        html_body: nil,
        from: nil,
        to: nil,
        cc: nil,
        subject: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "matches on body field - html_body fallback" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "body", "operator" => "contains", "value" => "critical"}]
        }
      }

      message = %{
        text_body: nil,
        html_body: "<p>This is critical</p>",
        from: nil,
        to: nil,
        cc: nil,
        subject: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "matches on has_attachment field" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "has_attachment", "operator" => "equals", "value" => "true"}]
        }
      }

      message = %{
        has_attachments: true,
        from: nil,
        to: nil,
        cc: nil,
        subject: nil,
        text_body: nil,
        html_body: nil
      }

      assert Filter.matches?(filter, message)
    end
  end

  describe "filter matching - edge cases" do
    test "handles nil field values gracefully" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "subject", "operator" => "contains", "value" => "test"}]
        }
      }

      message = %{
        subject: nil,
        from: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      refute Filter.matches?(filter, message)
    end

    test "handles empty string field values" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "subject", "operator" => "contains", "value" => "test"}]
        }
      }

      message = %{
        subject: "",
        from: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      refute Filter.matches?(filter, message)
    end

    test "handles empty rules list" do
      filter = %Filter{
        conditions: %{
          "match_type" => "all",
          "rules" => []
        }
      }

      message = %{
        subject: "Test",
        from: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      # Empty "all" should return true (vacuous truth)
      assert Filter.matches?(filter, message)
    end

    test "handles missing match_type - defaults to all" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "subject", "operator" => "contains", "value" => "test"}]
        }
      }

      message = %{
        subject: "test message",
        from: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "handles unicode in filter values" do
      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "subject", "operator" => "contains", "value" => ""}]
        }
      }

      message = %{
        subject: "Test ",
        from: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end

    test "handles very long field values" do
      long_subject = String.duplicate("a", 10000)

      filter = %Filter{
        conditions: %{
          "rules" => [%{"field" => "subject", "operator" => "contains", "value" => "aaaa"}]
        }
      }

      message = %{
        subject: long_subject,
        from: nil,
        to: nil,
        cc: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      assert Filter.matches?(filter, message)
    end
  end

  describe "apply_filters/2" do
    setup do
      user = user_fixture()
      {:ok, user: user}
    end

    test "applies matching filter actions", %{user: user} do
      {:ok, _filter} =
        Filters.create_filter(%{
          user_id: user.id,
          name: "Mark Read",
          conditions: %{
            "rules" => [%{"field" => "from", "operator" => "contains", "value" => "newsletter"}]
          },
          actions: %{"mark_as_read" => true}
        })

      message = %{
        id: 1,
        from: "newsletter@example.com",
        to: nil,
        cc: nil,
        subject: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      actions = Filters.apply_filters(user.id, message)

      assert actions["mark_as_read"] == true
    end

    test "merges actions from multiple matching filters", %{user: user} do
      {:ok, _filter1} =
        Filters.create_filter(%{
          user_id: user.id,
          name: "Filter 1",
          priority: 0,
          conditions: %{
            "rules" => [%{"field" => "from", "operator" => "contains", "value" => "example"}]
          },
          actions: %{"mark_as_read" => true}
        })

      {:ok, _filter2} =
        Filters.create_filter(%{
          user_id: user.id,
          name: "Filter 2",
          priority: 1,
          conditions: %{
            "rules" => [%{"field" => "from", "operator" => "contains", "value" => "example"}]
          },
          actions: %{"star" => true}
        })

      message = %{
        id: 1,
        from: "test@example.com",
        to: nil,
        cc: nil,
        subject: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      actions = Filters.apply_filters(user.id, message)

      assert actions["mark_as_read"] == true
      assert actions["star"] == true
    end

    test "stop_processing prevents further filter evaluation", %{user: user} do
      {:ok, _filter1} =
        Filters.create_filter(%{
          user_id: user.id,
          name: "Stop Here",
          priority: 0,
          stop_processing: true,
          conditions: %{
            "rules" => [%{"field" => "from", "operator" => "contains", "value" => "example"}]
          },
          actions: %{"mark_as_read" => true}
        })

      {:ok, _filter2} =
        Filters.create_filter(%{
          user_id: user.id,
          name: "Never Reaches",
          priority: 1,
          conditions: %{
            "rules" => [%{"field" => "from", "operator" => "contains", "value" => "example"}]
          },
          actions: %{"star" => true}
        })

      message = %{
        id: 1,
        from: "test@example.com",
        to: nil,
        cc: nil,
        subject: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      actions = Filters.apply_filters(user.id, message)

      assert actions["mark_as_read"] == true
      refute Map.has_key?(actions, "star")
    end

    test "returns empty map when no filters match", %{user: user} do
      {:ok, _filter} =
        Filters.create_filter(%{
          user_id: user.id,
          name: "No Match",
          conditions: %{
            "rules" => [%{"field" => "from", "operator" => "contains", "value" => "nomatch"}]
          },
          actions: %{"mark_as_read" => true}
        })

      message = %{
        id: 1,
        from: "test@example.com",
        to: nil,
        cc: nil,
        subject: nil,
        text_body: nil,
        html_body: nil,
        has_attachments: false
      }

      actions = Filters.apply_filters(user.id, message)

      assert actions == %{}
    end
  end

  describe "execute_actions/2" do
    test "returns message unchanged for empty actions" do
      message = %{id: 1}

      {:ok, result} = Filters.execute_actions(message, %{})

      assert result == message
    end
  end

  describe "filter validation edge cases" do
    setup do
      user = user_fixture()
      {:ok, user: user}
    end

    test "rejects filter with invalid field in rule", %{user: user} do
      attrs = %{
        user_id: user.id,
        name: "Invalid Field",
        conditions: %{
          "rules" => [%{"field" => "invalid_field", "operator" => "contains", "value" => "test"}]
        },
        actions: %{"mark_as_read" => true}
      }

      {:error, changeset} = Filters.create_filter(attrs)
      assert errors_on(changeset).conditions != nil
    end

    test "rejects filter with invalid operator", %{user: user} do
      attrs = %{
        user_id: user.id,
        name: "Invalid Operator",
        conditions: %{
          "rules" => [%{"field" => "from", "operator" => "invalid_op", "value" => "test"}]
        },
        actions: %{"mark_as_read" => true}
      }

      {:error, changeset} = Filters.create_filter(attrs)
      assert errors_on(changeset).conditions != nil
    end

    test "rejects filter with invalid action", %{user: user} do
      attrs = %{
        user_id: user.id,
        name: "Invalid Action",
        conditions: %{
          "rules" => [%{"field" => "from", "operator" => "contains", "value" => "test"}]
        },
        actions: %{"invalid_action" => true}
      }

      {:error, changeset} = Filters.create_filter(attrs)
      assert errors_on(changeset).actions != nil
    end

    test "rejects filter with invalid priority value", %{user: user} do
      attrs = %{
        user_id: user.id,
        name: "Invalid Priority",
        conditions: %{
          "rules" => [%{"field" => "from", "operator" => "contains", "value" => "test"}]
        },
        actions: %{"set_priority" => "invalid"}
      }

      {:error, changeset} = Filters.create_filter(attrs)
      assert errors_on(changeset).actions != nil
    end

    test "rejects forward_to without valid email", %{user: user} do
      attrs = %{
        user_id: user.id,
        name: "Invalid Forward",
        conditions: %{
          "rules" => [%{"field" => "from", "operator" => "contains", "value" => "test"}]
        },
        actions: %{"forward_to" => "notanemail"}
      }

      {:error, changeset} = Filters.create_filter(attrs)
      assert errors_on(changeset).actions != nil
    end

    test "allows duplicate filter names (no unique constraint)", %{user: user} do
      attrs = %{
        user_id: user.id,
        name: "Duplicate Name",
        conditions: %{
          "rules" => [%{"field" => "from", "operator" => "contains", "value" => "test"}]
        },
        actions: %{"mark_as_read" => true}
      }

      {:ok, filter1} = Filters.create_filter(attrs)
      {:ok, filter2} = Filters.create_filter(attrs)

      assert filter1.id != filter2.id
      assert filter1.name == filter2.name
    end
  end

  # Helper function to create test filters
  defp create_test_filter(user_id, name, priority) do
    Filters.create_filter(%{
      user_id: user_id,
      name: name,
      priority: priority,
      conditions: %{
        "match_type" => "all",
        "rules" => [%{"field" => "from", "operator" => "contains", "value" => "test"}]
      },
      actions: %{"mark_as_read" => true}
    })
  end
end
