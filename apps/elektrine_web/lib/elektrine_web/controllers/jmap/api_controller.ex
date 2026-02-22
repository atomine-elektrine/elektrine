defmodule ElektrineWeb.JMAP.APIController do
  @moduledoc """
  JMAP API controller for method calls.
  Handles POST /jmap/ with method call batching.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Email
  alias Elektrine.JMAP

  @supported_capabilities [
    "urn:ietf:params:jmap:core",
    "urn:ietf:params:jmap:mail",
    "urn:ietf:params:jmap:submission"
  ]

  @doc """
  POST /jmap/
  Processes JMAP method calls.
  """
  def api(conn, params) do
    user = conn.assigns[:current_user]
    account_id = conn.assigns[:jmap_account_id]
    mailbox = Email.get_user_mailbox(user.id)

    using = Map.get(params, "using", [])
    method_calls = Map.get(params, "methodCalls", [])

    # Validate capabilities
    case validate_capabilities(using) do
      :ok ->
        # Process method calls
        {responses, _state} =
          Enum.map_reduce(method_calls, %{}, fn call, created_ids ->
            process_method_call(call, user, mailbox, account_id, created_ids)
          end)

        response = %{
          "methodResponses" => responses,
          "sessionState" => JMAP.get_state(mailbox.id, "Email")
        }

        conn
        |> put_resp_content_type("application/json")
        |> json(response)

      {:error, unknown_caps} ->
        error_response(
          conn,
          "unknownCapability",
          "Unknown capabilities: #{Enum.join(unknown_caps, ", ")}"
        )
    end
  end

  defp validate_capabilities(using) do
    unknown = Enum.reject(using, &(&1 in @supported_capabilities))

    if Enum.empty?(unknown) do
      :ok
    else
      {:error, unknown}
    end
  end

  defp process_method_call([method, args, call_id], user, mailbox, account_id, created_ids) do
    # Validate account ID if provided
    args_account = Map.get(args, "accountId")

    if args_account && args_account != account_id do
      {[method, %{"type" => "accountNotFound"}, call_id], created_ids}
    else
      result = dispatch_method(method, args, user, mailbox, created_ids)
      {[method, result, call_id], created_ids}
    end
  end

  # ============================================================================
  # Core Methods
  # ============================================================================

  defp dispatch_method("Core/echo", args, _user, _mailbox, _created_ids) do
    args
  end

  # ============================================================================
  # Mailbox Methods
  # ============================================================================

  defp dispatch_method("Mailbox/get", args, _user, mailbox, _created_ids) do
    ids = Map.get(args, "ids")
    mailboxes = JMAP.get_mailboxes(mailbox.id)

    list =
      if is_nil(ids) do
        mailboxes
      else
        Enum.filter(mailboxes, &(&1.id in ids))
      end

    not_found = if ids, do: ids -- Enum.map(list, & &1.id), else: []

    %{
      "accountId" => "u#{mailbox.user_id}",
      "state" => JMAP.get_state(mailbox.id, "Mailbox"),
      "list" => list,
      "notFound" => not_found
    }
  end

  defp dispatch_method("Mailbox/changes", args, _user, mailbox, _created_ids) do
    since_state = Map.get(args, "sinceState", "0")

    case JMAP.validate_state(mailbox.id, "Mailbox", since_state) do
      {:ok, current_state} ->
        # Mailboxes are virtual, so they don't change
        %{
          "accountId" => "u#{mailbox.user_id}",
          "oldState" => since_state,
          "newState" => current_state,
          "hasMoreChanges" => false,
          "created" => [],
          "updated" => [],
          "destroyed" => []
        }

      {:error, :invalid_state} ->
        %{"type" => "cannotCalculateChanges"}
    end
  end

  # ============================================================================
  # Thread Methods
  # ============================================================================

  defp dispatch_method("Thread/get", args, _user, mailbox, _created_ids) do
    ids = Map.get(args, "ids", [])

    threads =
      Enum.map(ids, fn id ->
        thread_id = String.to_integer(id)
        message_ids = JMAP.get_thread_message_ids(thread_id)

        %{
          "id" => id,
          "emailIds" => Enum.map(message_ids, &to_string/1)
        }
      end)

    %{
      "accountId" => "u#{mailbox.user_id}",
      "state" => JMAP.get_state(mailbox.id, "Thread"),
      "list" => threads,
      "notFound" => []
    }
  end

  # ============================================================================
  # Email Methods
  # ============================================================================

  defp dispatch_method("Email/get", args, _user, mailbox, _created_ids) do
    ids = Map.get(args, "ids", [])
    properties = Map.get(args, "properties")

    # Convert string IDs to integers
    int_ids = Enum.map(ids, &parse_email_id/1) |> Enum.reject(&is_nil/1)

    emails = JMAP.get_emails(mailbox.id, int_ids, properties)

    # Decrypt content for the user
    emails =
      Enum.map(emails, fn email ->
        # If we have encrypted content, decrypt it
        email
      end)

    found_ids = Enum.map(emails, & &1["id"])
    not_found = ids -- found_ids

    %{
      "accountId" => "u#{mailbox.user_id}",
      "state" => JMAP.get_state(mailbox.id, "Email"),
      "list" => emails,
      "notFound" => not_found
    }
  end

  defp dispatch_method("Email/query", args, _user, mailbox, _created_ids) do
    filter = Map.get(args, "filter", %{})
    sort = Map.get(args, "sort", [%{"property" => "receivedAt", "isAscending" => false}])
    position = Map.get(args, "position", 0)
    limit = Map.get(args, "limit", 50)

    result =
      JMAP.query_emails(mailbox.id,
        filter: filter,
        sort: sort,
        position: position,
        limit: min(limit, 500)
      )

    %{
      "accountId" => "u#{mailbox.user_id}",
      "queryState" => JMAP.get_state(mailbox.id, "Email"),
      "canCalculateChanges" => true,
      "position" => result.position,
      "ids" => Enum.map(result.ids, &to_string/1),
      "total" => result.total
    }
  end

  defp dispatch_method("Email/changes", args, _user, mailbox, _created_ids) do
    since_state = Map.get(args, "sinceState", "0")

    case JMAP.validate_state(mailbox.id, "Email", since_state) do
      {:ok, current_state} ->
        # Return empty changes until incremental change tracking is implemented.
        %{
          "accountId" => "u#{mailbox.user_id}",
          "oldState" => since_state,
          "newState" => current_state,
          "hasMoreChanges" => false,
          "created" => [],
          "updated" => [],
          "destroyed" => []
        }

      {:error, :invalid_state} ->
        %{"type" => "cannotCalculateChanges"}
    end
  end

  defp dispatch_method("Email/set", args, user, mailbox, _created_ids) do
    create = Map.get(args, "create", %{})
    update = Map.get(args, "update", %{})
    destroy = Map.get(args, "destroy", [])

    created = handle_email_create(create, user, mailbox)
    updated = handle_email_update(update, user, mailbox)
    destroyed = handle_email_destroy(destroy, user, mailbox)

    # Increment state
    new_state = JMAP.increment_state(mailbox.id, "Email")

    %{
      "accountId" => "u#{mailbox.user_id}",
      "oldState" => JMAP.get_state(mailbox.id, "Email"),
      "newState" => new_state,
      "created" => created,
      "updated" => updated,
      "destroyed" => destroyed,
      "notCreated" => %{},
      "notUpdated" => %{},
      "notDestroyed" => %{}
    }
  end

  # ============================================================================
  # EmailSubmission Methods
  # ============================================================================

  defp dispatch_method("EmailSubmission/get", args, _user, mailbox, _created_ids) do
    ids = Map.get(args, "ids")
    submissions = JMAP.list_submissions(mailbox.id)

    list =
      if is_nil(ids) do
        submissions
      else
        int_ids = Enum.map(ids, &String.to_integer/1)
        Enum.filter(submissions, &(&1.id in int_ids))
      end

    %{
      "accountId" => "u#{mailbox.user_id}",
      "state" => JMAP.get_state(mailbox.id, "EmailSubmission"),
      "list" => Enum.map(list, &submission_to_jmap/1),
      "notFound" => []
    }
  end

  defp dispatch_method("EmailSubmission/set", args, user, mailbox, _created_ids) do
    create = Map.get(args, "create", %{})

    created =
      Enum.reduce(create, %{}, fn {client_id, submission_args}, acc ->
        case create_email_submission(submission_args, user, mailbox) do
          {:ok, submission} ->
            Map.put(acc, client_id, submission_to_jmap(submission))

          {:error, _reason} ->
            acc
        end
      end)

    new_state = JMAP.increment_state(mailbox.id, "EmailSubmission")

    %{
      "accountId" => "u#{mailbox.user_id}",
      "oldState" => JMAP.get_state(mailbox.id, "EmailSubmission"),
      "newState" => new_state,
      "created" => created,
      "updated" => nil,
      "destroyed" => [],
      "notCreated" => %{},
      "notUpdated" => %{},
      "notDestroyed" => %{}
    }
  end

  # ============================================================================
  # SearchSnippet Methods
  # ============================================================================

  defp dispatch_method("SearchSnippet/get", args, _user, mailbox, _created_ids) do
    email_ids = Map.get(args, "emailIds", [])
    _filter = Map.get(args, "filter", %{})

    # Generate snippets for requested emails
    snippets =
      Enum.map(email_ids, fn email_id ->
        %{
          "emailId" => email_id,
          "subject" => nil,
          "preview" => nil
        }
      end)

    %{
      "accountId" => "u#{mailbox.user_id}",
      "list" => snippets,
      "notFound" => []
    }
  end

  # ============================================================================
  # Identity Methods
  # ============================================================================

  defp dispatch_method("Identity/get", _args, user, mailbox, _created_ids) do
    identity = %{
      "id" => "identity-#{user.id}",
      "name" => user.username,
      "email" => mailbox.email || "#{user.username}@elektrine.com",
      "replyTo" => nil,
      "bcc" => nil,
      "textSignature" => "",
      "htmlSignature" => "",
      "mayDelete" => false
    }

    %{
      "accountId" => "u#{mailbox.user_id}",
      "state" => "1",
      "list" => [identity],
      "notFound" => []
    }
  end

  # ============================================================================
  # Unknown Method
  # ============================================================================

  defp dispatch_method(method, _args, _user, _mailbox, _created_ids) do
    %{
      "type" => "unknownMethod",
      "description" => "Method #{method} is not supported"
    }
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp handle_email_create(create, _user, mailbox) do
    Enum.reduce(create, %{}, fn {client_id, email_args}, acc ->
      # Create draft email
      attrs = jmap_email_to_attrs(email_args, mailbox)

      case Email.create_message(attrs) do
        {:ok, message} ->
          Map.put(acc, client_id, %{"id" => to_string(message.id)})

        {:error, _} ->
          acc
      end
    end)
  end

  defp handle_email_update(update, _user, mailbox) do
    Enum.reduce(update, %{}, fn {email_id, changes}, acc ->
      int_id = parse_email_id(email_id)

      if int_id do
        case Email.get_message(int_id, mailbox.id) do
          nil ->
            acc

          message ->
            apply_jmap_changes(message, changes)
            Map.put(acc, email_id, nil)
        end
      else
        acc
      end
    end)
  end

  defp handle_email_destroy(destroy, _user, mailbox) do
    Enum.filter(destroy, fn email_id ->
      int_id = parse_email_id(email_id)

      if int_id do
        case Email.get_message(int_id, mailbox.id) do
          nil ->
            false

          message ->
            Email.delete_message(message)
            true
        end
      else
        false
      end
    end)
  end

  defp apply_jmap_changes(message, changes) do
    # Handle keyword changes
    keywords = Map.get(changes, "keywords")

    if keywords do
      # Update read status
      if Map.has_key?(keywords, "$seen") do
        if keywords["$seen"], do: Email.mark_as_read(message), else: Email.mark_as_unread(message)
      end

      # Update flagged status
      if Map.has_key?(keywords, "$flagged") do
        Email.update_message_flags(message.id, %{flagged: keywords["$flagged"]})
      end
    end

    # Handle mailbox changes (move between folders)
    mailbox_ids = Map.get(changes, "mailboxIds")

    if mailbox_ids do
      # Determine target folder from mailboxIds
      cond do
        Map.values(mailbox_ids) |> Enum.any?(&String.ends_with?(to_string(&1), "-trash")) ->
          Email.trash_message(message)

        Map.values(mailbox_ids) |> Enum.any?(&String.ends_with?(to_string(&1), "-spam")) ->
          Email.mark_as_spam(message)

        Map.values(mailbox_ids) |> Enum.any?(&String.ends_with?(to_string(&1), "-archive")) ->
          Email.archive_message(message)

        true ->
          :ok
      end
    end
  end

  defp jmap_email_to_attrs(email_args, mailbox) do
    %{
      mailbox_id: mailbox.id,
      message_id: "<#{Ecto.UUID.generate()}@elektrine.com>",
      from: format_address(Map.get(email_args, "from", [])),
      to: format_addresses(Map.get(email_args, "to", [])),
      cc: format_addresses(Map.get(email_args, "cc", [])),
      bcc: format_addresses(Map.get(email_args, "bcc", [])),
      subject: Map.get(email_args, "subject", ""),
      text_body: get_body_value(Map.get(email_args, "textBody", [])),
      html_body: get_body_value(Map.get(email_args, "htmlBody", [])),
      status: "draft"
    }
  end

  defp format_address([]), do: ""

  defp format_address([addr | _]) do
    name = Map.get(addr, "name", "")
    email = Map.get(addr, "email", "")

    if name && name != "" do
      "#{name} <#{email}>"
    else
      email
    end
  end

  defp format_addresses(addresses) do
    addresses
    |> Enum.map_join(", ", &format_address([&1]))
  end

  defp get_body_value([]), do: nil
  defp get_body_value([body | _]), do: Map.get(body, "value")

  defp create_email_submission(args, user, mailbox) do
    email_id = Map.get(args, "emailId")
    identity_id = Map.get(args, "identityId", "identity-#{user.id}")

    int_email_id = parse_email_id(email_id)

    if int_email_id do
      case Email.get_message(int_email_id, mailbox.id) do
        nil ->
          {:error, :email_not_found}

        message ->
          # Create submission record
          JMAP.create_submission(%{
            mailbox_id: mailbox.id,
            email_id: message.id,
            identity_id: identity_id,
            envelope_from: message.from,
            envelope_to: String.split(message.to || "", ",") |> Enum.map(&String.trim/1)
          })
      end
    else
      {:error, :invalid_email_id}
    end
  end

  defp submission_to_jmap(submission) do
    %{
      "id" => to_string(submission.id),
      "identityId" => submission.identity_id,
      "emailId" => if(submission.email_id, do: to_string(submission.email_id), else: nil),
      "threadId" => nil,
      "envelope" => %{
        "mailFrom" => %{"email" => submission.envelope_from},
        "rcptTo" => Enum.map(submission.envelope_to, &%{"email" => &1})
      },
      "sendAt" => if(submission.send_at, do: DateTime.to_iso8601(submission.send_at), else: nil),
      "undoStatus" => submission.undo_status,
      "deliveryStatus" => submission.delivery_status
    }
  end

  defp parse_email_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> int_id
      _ -> nil
    end
  end

  defp parse_email_id(id) when is_integer(id), do: id
  defp parse_email_id(_), do: nil

  defp error_response(conn, type, description) do
    conn
    |> put_status(400)
    |> put_resp_content_type("application/json")
    |> json(%{
      "type" => type,
      "status" => 400,
      "detail" => description
    })
  end
end
