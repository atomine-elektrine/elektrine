defmodule ElektrineWeb.JMAPControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.Email
  alias Elektrine.JMAP

  setup do
    user = AccountsFixtures.user_fixture()
    recipient = AccountsFixtures.user_fixture()
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
    {:ok, recipient_mailbox} = Email.ensure_user_has_mailbox(recipient)

    %{
      user: user,
      mailbox: mailbox,
      recipient_mailbox: recipient_mailbox
    }
  end

  describe "GET /.well-known/jmap" do
    test "includes submission primary account and a live eventsource endpoint", %{
      conn: conn,
      user: user
    } do
      conn =
        conn
        |> jmap_conn(user)
        |> get("/.well-known/jmap")

      response = json_response(conn, 200)

      assert response["primaryAccounts"]["urn:ietf:params:jmap:mail"] == "u#{user.id}"
      assert response["primaryAccounts"]["urn:ietf:params:jmap:submission"] == "u#{user.id}"
      assert String.contains?(response["eventSourceUrl"], "/jmap/eventsource")
    end
  end

  describe "POST /jmap/" do
    test "Mailbox/get returns JMAP mailbox property names", %{conn: conn, user: user} do
      conn =
        conn
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [["Mailbox/get", %{"accountId" => "u#{user.id}"}, "c1"]]
        })

      response = json_response(conn, 200)
      [_method, body, _call_id] = hd(response["methodResponses"])
      inbox = Enum.find(body["list"], &(&1["role"] == "inbox"))

      assert Map.has_key?(inbox, "sortOrder")
      assert Map.has_key?(inbox, "totalEmails")
      assert Map.has_key?(inbox, "unreadEmails")
      refute Map.has_key?(inbox, "sort_order")
      refute Map.has_key?(inbox, "total_emails")
    end

    test "Email/get decrypts stored bodies for JMAP clients", %{
      conn: conn,
      user: user,
      mailbox: mailbox
    } do
      {:ok, message} =
        Email.create_message(%{
          from: "sender@example.com",
          to: mailbox.email,
          subject: "Encrypted fetch",
          text_body: "Encrypted hello from JMAP",
          message_id: "<jmap-email-get-#{System.unique_integer([:positive])}@example.com>",
          mailbox_id: mailbox.id
        })

      conn =
        conn
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [
            [
              "Email/get",
              %{
                "accountId" => "u#{user.id}",
                "ids" => [to_string(message.id)],
                "properties" => ["textBody", "preview"]
              },
              "c1"
            ]
          ]
        })

      response = json_response(conn, 200)
      [_method, body, _call_id] = hd(response["methodResponses"])
      [email] = body["list"]

      assert get_in(email, ["textBody", Access.at(0), "value"]) == "Encrypted hello from JMAP"
      assert email["preview"] =~ "Encrypted hello from JMAP"
    end

    test "Email/set applies mailboxIds patch moves", %{conn: conn, user: user, mailbox: mailbox} do
      {:ok, message} =
        Email.create_message(%{
          from: "sender@example.com",
          to: mailbox.email,
          subject: "Archive me",
          text_body: "move",
          message_id: "<jmap-move-#{System.unique_integer([:positive])}@example.com>",
          mailbox_id: mailbox.id
        })

      conn =
        conn
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [
            [
              "Email/set",
              %{
                "accountId" => "u#{user.id}",
                "update" => %{
                  to_string(message.id) => %{
                    "mailboxIds/mb-#{mailbox.id}-archive" => true
                  }
                }
              },
              "c1"
            ]
          ]
        })

      response = json_response(conn, 200)
      [_method, body, _call_id] = hd(response["methodResponses"])
      updated = Email.get_message(message.id, mailbox.id)

      assert updated.archived
      assert body["oldState"] != body["newState"]
    end

    test "batched Email/set plus EmailSubmission/set sends mail and records created ids", %{
      conn: conn,
      user: user,
      mailbox: mailbox,
      recipient_mailbox: recipient_mailbox
    } do
      conn =
        conn
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [
            [
              "Email/set",
              %{
                "accountId" => "u#{user.id}",
                "create" => %{
                  "draft1" => %{
                    "from" => [%{"email" => mailbox.email}],
                    "to" => [%{"email" => recipient_mailbox.email}],
                    "subject" => "Sent through JMAP",
                    "textBody" => [%{"value" => "hello from submission"}]
                  }
                }
              },
              "c1"
            ],
            [
              "EmailSubmission/set",
              %{
                "accountId" => "u#{user.id}",
                "create" => %{
                  "sub1" => %{
                    "emailId" => "#draft1",
                    "identityId" => "identity-#{user.id}"
                  }
                }
              },
              "c2"
            ]
          ]
        })

      response = json_response(conn, 200)
      submissions = JMAP.list_submissions(mailbox.id)
      recipient_messages = Email.list_messages(recipient_mailbox.id, 50, 0)

      assert response["createdIds"]["draft1"]
      assert Enum.any?(recipient_messages, &(&1.subject == "Sent through JMAP"))
      assert Enum.any?(submissions, &(&1.undo_status == "final"))
    end

    test "Email/changes reports created and destroyed ids", %{
      conn: conn,
      user: user,
      mailbox: mailbox
    } do
      initial_conn =
        conn
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [["Email/query", %{"accountId" => "u#{user.id}"}, "c1"]]
        })

      initial_response = json_response(initial_conn, 200)
      [_method, query_body, _call_id] = hd(initial_response["methodResponses"])
      initial_state = query_body["queryState"]

      {:ok, message} =
        Email.create_message(%{
          from: "creator@example.com",
          to: mailbox.email,
          subject: "Created for changes",
          text_body: "delta body",
          message_id: "<jmap-changes-created-#{System.unique_integer([:positive])}@example.com>",
          mailbox_id: mailbox.id
        })

      created_conn =
        build_conn()
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [
            [
              "Email/changes",
              %{"accountId" => "u#{user.id}", "sinceState" => initial_state},
              "c2"
            ]
          ]
        })

      created_response = json_response(created_conn, 200)
      [_method, created_body, _call_id] = hd(created_response["methodResponses"])

      assert to_string(message.id) in created_body["created"]

      {:ok, _deleted_message} = Email.delete_message(message)

      destroyed_conn =
        build_conn()
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [
            [
              "Email/changes",
              %{"accountId" => "u#{user.id}", "sinceState" => created_body["newState"]},
              "c3"
            ]
          ]
        })

      destroyed_response = json_response(destroyed_conn, 200)
      [_method, destroyed_body, _call_id] = hd(destroyed_response["methodResponses"])

      assert to_string(message.id) in destroyed_body["destroyed"]
    end

    test "Email/changes coalesces repeated updates for the same email", %{
      conn: conn,
      user: user,
      mailbox: mailbox
    } do
      {:ok, message} =
        Email.create_message(%{
          from: "updates@example.com",
          to: mailbox.email,
          subject: "Repeated updates",
          text_body: "before",
          message_id: "<jmap-repeated-updates-#{System.unique_integer([:positive])}@example.com>",
          mailbox_id: mailbox.id
        })

      baseline_conn =
        conn
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [["Email/get", %{"accountId" => "u#{user.id}"}, "c1"]]
        })

      baseline_response = json_response(baseline_conn, 200)
      [_method, baseline_body, _call_id] = hd(baseline_response["methodResponses"])
      baseline_state = baseline_body["state"]

      {:ok, updated_message} = Email.update_message(message, %{flagged: true})
      {:ok, _updated_message} = Email.update_message(updated_message, %{read: true})

      changes_conn =
        build_conn()
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [
            [
              "Email/changes",
              %{"accountId" => "u#{user.id}", "sinceState" => baseline_state},
              "c2"
            ]
          ]
        })

      changes_response = json_response(changes_conn, 200)
      [_method, changes_body, _call_id] = hd(changes_response["methodResponses"])

      assert changes_body["updated"] == [to_string(message.id)]
    end

    test "Email/query supports filter conditions and rejects unsupported filters", %{
      conn: conn,
      user: user,
      mailbox: mailbox
    } do
      {:ok, alpha_message} =
        Email.create_message(%{
          from: "alpha@example.com",
          to: mailbox.email,
          subject: "Alpha subject",
          text_body: "one",
          message_id: "<jmap-query-alpha-#{System.unique_integer([:positive])}@example.com>",
          mailbox_id: mailbox.id
        })

      {:ok, beta_message} =
        Email.create_message(%{
          from: "beta@example.com",
          to: mailbox.email,
          subject: "Beta subject",
          text_body: "two",
          message_id: "<jmap-query-beta-#{System.unique_integer([:positive])}@example.com>",
          mailbox_id: mailbox.id
        })

      conn =
        conn
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [
            [
              "Email/query",
              %{
                "accountId" => "u#{user.id}",
                "filter" => %{
                  "operator" => "OR",
                  "conditions" => [
                    %{"subject" => "Alpha"},
                    %{"from" => "beta@example.com"}
                  ]
                }
              },
              "c1"
            ],
            [
              "Email/query",
              %{
                "accountId" => "u#{user.id}",
                "filter" => %{"text" => "unsupported"}
              },
              "c2"
            ]
          ]
        })

      response = json_response(conn, 200)
      [_method, filtered_body, _call_id] = Enum.at(response["methodResponses"], 0)
      [_method, rejected_body, _call_id] = Enum.at(response["methodResponses"], 1)

      assert Enum.sort(filtered_body["ids"]) ==
               Enum.sort([to_string(alpha_message.id), to_string(beta_message.id)])

      assert rejected_body["type"] == "unsupportedFilter"
    end

    test "Email/query does not advertise queryChanges support and queryChanges fails cleanly", %{
      conn: conn,
      user: user,
      mailbox: mailbox
    } do
      {:ok, _message} =
        Email.create_message(%{
          from: "querychanges@example.com",
          to: mailbox.email,
          subject: "Query changes",
          text_body: "body",
          message_id: "<jmap-querychanges-#{System.unique_integer([:positive])}@example.com>",
          mailbox_id: mailbox.id
        })

      conn =
        conn
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [
            ["Email/query", %{"accountId" => "u#{user.id}"}, "c1"],
            [
              "Email/queryChanges",
              %{"accountId" => "u#{user.id}", "sinceQueryState" => "0"},
              "c2"
            ]
          ]
        })

      response = json_response(conn, 200)
      [_method, query_body, _call_id] = Enum.at(response["methodResponses"], 0)
      [_method, query_changes_body, _call_id] = Enum.at(response["methodResponses"], 1)

      assert query_body["canCalculateChanges"] == false
      assert query_changes_body["type"] == "cannotCalculateChanges"
    end

    test "SearchSnippet/get returns subject and preview text", %{
      conn: conn,
      user: user,
      mailbox: mailbox
    } do
      {:ok, message} =
        Email.create_message(%{
          from: "snippet@example.com",
          to: mailbox.email,
          subject: "Snippet subject",
          html_body: "<p>Snippet preview body</p>",
          message_id: "<jmap-snippet-#{System.unique_integer([:positive])}@example.com>",
          mailbox_id: mailbox.id
        })

      conn =
        conn
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [
            [
              "SearchSnippet/get",
              %{
                "accountId" => "u#{user.id}",
                "emailIds" => [to_string(message.id), "99999999"]
              },
              "c1"
            ]
          ]
        })

      response = json_response(conn, 200)
      [_method, body, _call_id] = hd(response["methodResponses"])
      [snippet] = body["list"]

      assert snippet["subject"] == "Snippet subject"
      assert snippet["preview"] =~ "Snippet preview body"
      assert body["notFound"] == ["99999999"]
    end

    test "EmailSubmission/set can cancel a pending submission", %{
      conn: conn,
      user: user,
      mailbox: mailbox
    } do
      {:ok, message} =
        Email.create_message(%{
          from: mailbox.email,
          to: "pending@example.com",
          subject: "Pending submission",
          text_body: "cancel me",
          status: "draft",
          message_id:
            "<jmap-cancel-submission-#{System.unique_integer([:positive])}@example.com>",
          mailbox_id: mailbox.id
        })

      send_at = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      {:ok, submission} =
        JMAP.create_submission(%{
          mailbox_id: mailbox.id,
          email_id: message.id,
          identity_id: "identity-#{user.id}",
          envelope_from: mailbox.email,
          envelope_to: ["pending@example.com"],
          send_at: send_at,
          undo_status: "pending",
          delivery_status: %{
            "status" => "scheduled",
            "scheduledAt" => DateTime.to_iso8601(send_at),
            "jobId" => 123
          }
        })

      conn =
        conn
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [
            [
              "EmailSubmission/set",
              %{
                "accountId" => "u#{user.id}",
                "update" => %{
                  to_string(submission.id) => %{"undoStatus" => "canceled"}
                }
              },
              "c1"
            ]
          ]
        })

      response = json_response(conn, 200)
      [_method, body, _call_id] = hd(response["methodResponses"])
      updated_submission = JMAP.get_submission(submission.id, mailbox.id)

      assert body["updated"] == %{to_string(submission.id) => nil}
      assert updated_submission.undo_status == "canceled"
      assert updated_submission.delivery_status["status"] == "canceled"
    end

    test "EmailSubmission/set resumes a stale pending submission instead of returning it unsent",
         %{
           conn: conn,
           user: user,
           mailbox: mailbox,
           recipient_mailbox: recipient_mailbox
         } do
      {:ok, draft} =
        Email.create_message(%{
          from: mailbox.email,
          to: recipient_mailbox.email,
          subject: "Resume stale submission",
          text_body: "resume me",
          status: "draft",
          message_id:
            "<jmap-resume-submission-#{System.unique_integer([:positive])}@example.com>",
          mailbox_id: mailbox.id
        })

      {:ok, submission} =
        JMAP.create_submission(%{
          mailbox_id: mailbox.id,
          email_id: draft.id,
          identity_id: "identity-#{user.id}",
          envelope_from: mailbox.email,
          envelope_to: [recipient_mailbox.email],
          send_at: DateTime.utc_now() |> DateTime.truncate(:second),
          undo_status: "pending",
          delivery_status: %{"status" => "queued"}
        })

      conn =
        conn
        |> jmap_conn(user)
        |> post("/jmap/", %{
          "using" => using_capabilities(),
          "methodCalls" => [
            [
              "EmailSubmission/set",
              %{
                "accountId" => "u#{user.id}",
                "create" => %{
                  "sub1" => %{
                    "emailId" => to_string(draft.id),
                    "identityId" => "identity-#{user.id}"
                  }
                }
              },
              "c1"
            ]
          ]
        })

      response = json_response(conn, 200)
      [_method, body, _call_id] = hd(response["methodResponses"])
      refreshed_submission = JMAP.get_submission(submission.id, mailbox.id)
      recipient_messages = Email.list_messages(recipient_mailbox.id, 50, 0)

      assert get_in(body, ["created", "sub1", "id"]) == to_string(submission.id)
      assert refreshed_submission.undo_status == "final"
      assert Enum.any?(recipient_messages, &(&1.subject == "Resume stale submission"))
    end
  end

  describe "GET /jmap/download/:account_id/:blob_id/:name" do
    test "downloads raw message blobs for normal emails", %{
      conn: conn,
      user: user,
      mailbox: mailbox
    } do
      {:ok, message} =
        Email.create_message(%{
          from: "sender@example.com",
          to: mailbox.email,
          subject: "Blob source",
          text_body: "raw body",
          message_id: "<jmap-blob-#{System.unique_integer([:positive])}@example.com>",
          mailbox_id: mailbox.id
        })

      conn =
        conn
        |> jmap_conn(user)
        |> get("/jmap/download/u#{user.id}/#{message.id}/source.eml")

      body = response(conn, 200)

      assert body =~ "Subject: Blob source"
      assert body =~ "raw body"
    end
  end

  defp jmap_conn(conn, user) do
    credentials =
      Base.encode64("#{user.username}:#{AccountsFixtures.valid_user_password()}")

    conn
    |> put_req_header("authorization", "Basic #{credentials}")
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp using_capabilities do
    [
      "urn:ietf:params:jmap:core",
      "urn:ietf:params:jmap:mail",
      "urn:ietf:params:jmap:submission"
    ]
  end
end
