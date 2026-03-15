defmodule ElektrineWeb.JMAP.APIController do
  @moduledoc """
  JMAP API controller for method calls.
  Handles POST /jmap/ with method call batching.
  """
  use ElektrineEmailWeb, :controller
  import Ecto.Query

  alias Elektrine.Email
  alias Elektrine.Email.{SendEmailWorker, Sender}
  alias Elektrine.JMAP
  alias Elektrine.Repo
  alias Oban.Job

  @supported_capabilities [
    "urn:ietf:params:jmap:core",
    "urn:ietf:params:jmap:mail",
    "urn:ietf:params:jmap:submission"
  ]

  @mailbox_roles ~w(inbox feed ledger stack sent drafts trash spam archive)

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

    case validate_capabilities(using) do
      :ok ->
        {responses, created_ids} =
          Enum.map_reduce(method_calls, %{}, fn call, created_ids ->
            process_method_call(call, user, mailbox, account_id, created_ids)
          end)

        response =
          %{
            "methodResponses" => responses,
            "sessionState" => JMAP.get_session_state(mailbox.id)
          }
          |> maybe_put_created_ids(created_ids)

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

  defp process_method_call([method, args, call_id], user, mailbox, account_id, created_ids)
       when is_map(args) do
    args = resolve_creation_ids(args, created_ids)
    args_account = Map.get(args, "accountId")

    if args_account && args_account != account_id do
      {[method, %{"type" => "accountNotFound"}, call_id], created_ids}
    else
      result = dispatch_method(method, args, user, mailbox, created_ids)
      updated_created_ids = Map.merge(created_ids, extract_created_ids(result))
      {[method, result, call_id], updated_created_ids}
    end
  end

  defp process_method_call(_invalid_call, _user, _mailbox, _account_id, created_ids) do
    {["error", %{"type" => "invalidArguments"}, "0"], created_ids}
  end

  # ============================================================================
  # Core Methods
  # ============================================================================

  defp dispatch_method("Core/echo", args, _user, _mailbox, _created_ids), do: args

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
        Enum.filter(mailboxes, &(Map.get(&1, "id") in ids))
      end

    not_found = if ids, do: ids -- Enum.map(list, &Map.get(&1, "id")), else: []

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
        updated =
          if since_state == current_state do
            []
          else
            JMAP.get_mailboxes(mailbox.id) |> Enum.map(&Map.fetch!(&1, "id"))
          end

        %{
          "accountId" => "u#{mailbox.user_id}",
          "oldState" => since_state,
          "newState" => current_state,
          "hasMoreChanges" => false,
          "created" => [],
          "updated" => updated,
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

    {threads, not_found} =
      Enum.reduce(ids, {[], []}, fn id, {threads_acc, not_found_acc} ->
        case parse_email_id(id) do
          nil ->
            {threads_acc, not_found_acc ++ [id]}

          thread_id ->
            message_ids = JMAP.get_thread_message_ids(thread_id, mailbox.id)

            if message_ids == [] do
              {threads_acc, not_found_acc ++ [id]}
            else
              thread = %{
                "id" => id,
                "emailIds" => Enum.map(message_ids, &to_string/1)
              }

              {threads_acc ++ [thread], not_found_acc}
            end
        end
      end)

    %{
      "accountId" => "u#{mailbox.user_id}",
      "state" => JMAP.get_state(mailbox.id, "Thread"),
      "list" => threads,
      "notFound" => not_found
    }
  end

  # ============================================================================
  # Email Methods
  # ============================================================================

  defp dispatch_method("Email/get", args, _user, mailbox, _created_ids) do
    properties = Map.get(args, "properties")

    ids =
      case Map.get(args, "ids") do
        nil ->
          case JMAP.query_emails(mailbox.id, limit: 500) do
            {:ok, result} -> Enum.map(result.ids, &to_string/1)
            {:error, _reason} -> []
          end

        provided_ids ->
          provided_ids
      end

    int_ids = Enum.map(ids, &parse_email_id/1) |> Enum.reject(&is_nil/1)
    emails = JMAP.get_emails(mailbox.id, int_ids, properties)
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

    case JMAP.query_emails(mailbox.id,
           filter: filter,
           sort: sort,
           position: position,
           limit: min(limit, 500)
         ) do
      {:ok, result} ->
        %{
          "accountId" => "u#{mailbox.user_id}",
          "queryState" => JMAP.get_state(mailbox.id, "Email"),
          "canCalculateChanges" => false,
          "position" => result.position,
          "ids" => Enum.map(result.ids, &to_string/1),
          "total" => result.total
        }

      {:error, reason} ->
        query_error(reason)
    end
  end

  defp dispatch_method("Email/queryChanges", args, _user, mailbox, _created_ids) do
    since_query_state = Map.get(args, "sinceQueryState", "0")
    current_state = JMAP.get_state(mailbox.id, "Email")

    case JMAP.validate_state(mailbox.id, "Email", since_query_state) do
      {:ok, ^current_state} when since_query_state == current_state ->
        %{
          "accountId" => "u#{mailbox.user_id}",
          "oldQueryState" => since_query_state,
          "newQueryState" => current_state,
          "total" => nil,
          "removed" => [],
          "added" => []
        }

      {:ok, _current_state} ->
        %{"type" => "cannotCalculateChanges"}

      _ ->
        %{"type" => "cannotCalculateChanges"}
    end
  end

  defp dispatch_method("Email/changes", args, _user, mailbox, _created_ids) do
    since_state = Map.get(args, "sinceState", "0")
    current_state = JMAP.get_state(mailbox.id, "Email")

    case JMAP.validate_state(mailbox.id, "Email", since_state) do
      {:ok, ^current_state} when since_state == current_state ->
        %{
          "accountId" => "u#{mailbox.user_id}",
          "oldState" => since_state,
          "newState" => current_state,
          "hasMoreChanges" => false,
          "created" => [],
          "updated" => [],
          "destroyed" => []
        }

      {:ok, _validated_state} ->
        case JMAP.email_changes_since(mailbox.id, since_state) do
          {:ok, changes} ->
            Map.put(changes, "accountId", "u#{mailbox.user_id}")

          {:error, :invalid_state} ->
            %{"type" => "cannotCalculateChanges"}
        end

      _ ->
        %{"type" => "cannotCalculateChanges"}
    end
  end

  defp dispatch_method("Email/set", args, user, mailbox, _created_ids) do
    create = Map.get(args, "create", %{})
    update = Map.get(args, "update", %{})
    destroy = Map.get(args, "destroy", [])
    old_state = JMAP.get_state(mailbox.id, "Email")

    {created, not_created} = handle_email_create(create, user, mailbox)
    {updated, not_updated} = handle_email_update(update, user, mailbox)
    {destroyed, not_destroyed} = handle_email_destroy(destroy, user, mailbox)
    new_state = JMAP.get_state(mailbox.id, "Email")

    %{
      "accountId" => "u#{mailbox.user_id}",
      "oldState" => old_state,
      "newState" => new_state,
      "created" => created,
      "updated" => updated,
      "destroyed" => destroyed,
      "notCreated" => not_created,
      "notUpdated" => not_updated,
      "notDestroyed" => not_destroyed
    }
  end

  # ============================================================================
  # EmailSubmission Methods
  # ============================================================================

  defp dispatch_method("EmailSubmission/get", args, _user, mailbox, _created_ids) do
    ids = Map.get(args, "ids")
    submissions = JMAP.list_submissions(mailbox.id)

    {list, not_found} =
      if is_nil(ids) do
        {submissions, []}
      else
        Enum.reduce(ids, {[], []}, fn id, {list_acc, missing_acc} ->
          case parse_email_id(id) do
            nil ->
              {list_acc, missing_acc ++ [id]}

            int_id ->
              case Enum.find(submissions, &(&1.id == int_id)) do
                nil -> {list_acc, missing_acc ++ [id]}
                submission -> {list_acc ++ [submission], missing_acc}
              end
          end
        end)
      end

    %{
      "accountId" => "u#{mailbox.user_id}",
      "state" => JMAP.get_state(mailbox.id, "EmailSubmission"),
      "list" => Enum.map(list, &submission_to_jmap/1),
      "notFound" => not_found
    }
  end

  defp dispatch_method("EmailSubmission/set", args, user, mailbox, _created_ids) do
    create = Map.get(args, "create", %{})
    update = Map.get(args, "update", %{})
    old_state = JMAP.get_state(mailbox.id, "EmailSubmission")

    {created, not_created} =
      Enum.reduce(create, {%{}, %{}}, fn {client_id, submission_args},
                                         {created_acc, failed_acc} ->
        case create_email_submission(submission_args, user, mailbox) do
          {:ok, submission} ->
            {Map.put(created_acc, client_id, submission_to_jmap(submission)), failed_acc}

          {:error, reason} ->
            failure = %{
              "type" => "invalidProperties",
              "description" => submission_error(reason)
            }

            {created_acc, Map.put(failed_acc, client_id, failure)}
        end
      end)

    {updated, not_updated} = handle_submission_update(update, mailbox)
    new_state = JMAP.get_state(mailbox.id, "EmailSubmission")

    %{
      "accountId" => "u#{mailbox.user_id}",
      "oldState" => old_state,
      "newState" => new_state,
      "created" => created,
      "updated" => updated,
      "destroyed" => [],
      "notCreated" => not_created,
      "notUpdated" => not_updated,
      "notDestroyed" => %{}
    }
  end

  # ============================================================================
  # SearchSnippet Methods
  # ============================================================================

  defp dispatch_method("SearchSnippet/get", args, _user, mailbox, _created_ids) do
    email_ids = Map.get(args, "emailIds", [])

    {snippets, not_found} =
      Enum.reduce(email_ids, {[], []}, fn email_id, {snippets_acc, not_found_acc} ->
        with int_id when is_integer(int_id) <- parse_email_id(email_id),
             %{} = message <- Email.get_message(int_id, mailbox.id) do
          snippet = %{
            "emailId" => email_id,
            "subject" => nil_if_blank(message.subject),
            "preview" => search_preview(message)
          }

          {snippets_acc ++ [snippet], not_found_acc}
        else
          _ -> {snippets_acc, not_found_acc ++ [email_id]}
        end
      end)

    %{
      "accountId" => "u#{mailbox.user_id}",
      "list" => snippets,
      "notFound" => not_found
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
    Enum.reduce(create, {%{}, %{}}, fn {client_id, email_args}, {created_acc, failed_acc} ->
      attrs = jmap_email_to_attrs(email_args, mailbox)

      case Email.create_message(attrs) do
        {:ok, message} ->
          {Map.put(created_acc, client_id, %{"id" => to_string(message.id)}), failed_acc}

        {:error, reason} ->
          failure = %{"type" => "invalidProperties", "description" => inspect(reason)}
          {created_acc, Map.put(failed_acc, client_id, failure)}
      end
    end)
  end

  defp handle_email_update(update, _user, mailbox) do
    Enum.reduce(update, {%{}, %{}}, fn {email_id, changes}, {updated_acc, failed_acc} ->
      int_id = parse_email_id(email_id)

      cond do
        is_nil(int_id) ->
          failure = %{"type" => "notFound"}
          {updated_acc, Map.put(failed_acc, email_id, failure)}

        true ->
          case Email.get_message(int_id, mailbox.id) do
            nil ->
              failure = %{"type" => "notFound"}
              {updated_acc, Map.put(failed_acc, email_id, failure)}

            message ->
              case apply_jmap_changes(message, changes) do
                :ok ->
                  {Map.put(updated_acc, email_id, nil), failed_acc}

                {:error, reason} ->
                  failure = %{"type" => "invalidProperties", "description" => inspect(reason)}
                  {updated_acc, Map.put(failed_acc, email_id, failure)}
              end
          end
      end
    end)
  end

  defp handle_email_destroy(destroy, _user, mailbox) do
    Enum.reduce(destroy, {[], %{}}, fn email_id, {destroyed_acc, failed_acc} ->
      int_id = parse_email_id(email_id)

      cond do
        is_nil(int_id) ->
          {destroyed_acc, Map.put(failed_acc, email_id, %{"type" => "notFound"})}

        true ->
          case Email.get_message(int_id, mailbox.id) do
            nil ->
              {destroyed_acc, Map.put(failed_acc, email_id, %{"type" => "notFound"})}

            message ->
              case Email.delete_message(message) do
                {:ok, _deleted} ->
                  {destroyed_acc ++ [email_id], failed_acc}

                {:error, reason} ->
                  failure = %{"type" => "serverFail", "description" => inspect(reason)}
                  {destroyed_acc, Map.put(failed_acc, email_id, failure)}
              end
          end
      end
    end)
  end

  defp apply_jmap_changes(message, changes) do
    changes = normalize_patch_object(changes)
    keywords = Map.get(changes, "keywords", %{})

    result =
      cond do
        Map.has_key?(keywords, "$seen") and keywords["$seen"] in [false, nil] ->
          Email.mark_as_unread(message)

        Map.has_key?(keywords, "$seen") ->
          Email.mark_as_read(message)

        true ->
          {:ok, message}
      end

    with {:ok, _message} <- result,
         {:ok, _message} <- maybe_update_flagged(message, keywords),
         {:ok, _message} <- maybe_apply_mailbox_changes(message, Map.get(changes, "mailboxIds")) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      :ok -> :ok
    end
  end

  defp maybe_update_flagged(message, keywords) do
    if Map.has_key?(keywords, "$flagged") do
      Email.update_message(message, %{flagged: keywords["$flagged"] == true})
    else
      {:ok, message}
    end
  end

  defp maybe_apply_mailbox_changes(message, mailbox_ids) when is_map(mailbox_ids) do
    attrs = mailbox_update_attrs(mailbox_ids)

    if map_size(attrs) == 0 do
      {:ok, message}
    else
      Email.update_message(message, attrs)
    end
  end

  defp maybe_apply_mailbox_changes(message, _mailbox_ids), do: {:ok, message}

  defp mailbox_update_attrs(mailbox_ids) do
    active_ids =
      mailbox_ids
      |> Enum.filter(fn {_mailbox_id, enabled} -> enabled == true end)
      |> Enum.map(&elem(&1, 0))

    cond do
      has_mailbox_role?(active_ids, "trash") ->
        %{deleted: true}

      has_mailbox_role?(active_ids, "spam") ->
        %{spam: true, deleted: false, archived: false}

      has_mailbox_role?(active_ids, "archive") ->
        %{archived: true, deleted: false, spam: false}

      has_mailbox_role?(active_ids, "sent") ->
        %{status: "sent", deleted: false, spam: false, archived: false, category: nil}

      has_mailbox_role?(active_ids, "drafts") ->
        %{status: "draft", deleted: false, spam: false, archived: false, category: nil}

      role = Enum.find(@mailbox_roles, &has_mailbox_role?(active_ids, &1)) ->
        %{category: role, deleted: false, spam: false, archived: false}

      true ->
        %{}
    end
  end

  defp has_mailbox_role?(mailbox_ids, role) do
    Enum.any?(mailbox_ids, &String.ends_with?(&1, "-#{role}"))
  end

  defp jmap_email_to_attrs(email_args, mailbox) do
    %{
      mailbox_id: mailbox.id,
      message_id: "<#{Ecto.UUID.generate()}@elektrine.com>",
      from: first_address_email(Map.get(email_args, "from")) || mailbox.email,
      to: format_addresses(Map.get(email_args, "to", [])),
      cc: format_addresses(Map.get(email_args, "cc", [])),
      bcc: format_addresses(Map.get(email_args, "bcc", [])),
      subject: Map.get(email_args, "subject", ""),
      text_body: get_body_value(Map.get(email_args, "textBody", [])),
      html_body: get_body_value(Map.get(email_args, "htmlBody", [])),
      status: "draft"
    }
  end

  defp first_address_email([addr | _]), do: Map.get(addr, "email")
  defp first_address_email(_), do: nil

  defp format_addresses(addresses) do
    addresses
    |> List.wrap()
    |> Enum.map_join(", ", &Map.get(&1, "email", ""))
    |> case do
      "" -> nil
      formatted -> formatted
    end
  end

  defp get_body_value([]), do: nil
  defp get_body_value([body | _]), do: Map.get(body, "value")
  defp get_body_value(_), do: nil

  defp create_email_submission(args, user, mailbox) do
    identity_id = Map.get(args, "identityId", "identity-#{user.id}")

    with int_email_id when is_integer(int_email_id) <- parse_email_id(Map.get(args, "emailId")),
         %{} = message <- Email.get_message(int_email_id, mailbox.id),
         {:ok, send_at} <- parse_send_at(Map.get(args, "sendAt")),
         {:ok, submission_slot} <- ensure_submission_slot(mailbox.id, message.id),
         params <- submission_message_params(message, mailbox.email),
         {:ok, submission} <-
           create_or_reuse_submission(
             submission_slot,
             mailbox,
             message,
             identity_id,
             params,
             send_at
           ) do
      case submission_slot do
        {:reuse, _existing_submission} ->
          {:ok, submission}

        :new ->
          deliver_submission(submission, user.id, params, send_at)

        {:resume, _existing_submission} ->
          deliver_submission(submission, user.id, params, send_at)
      end
    else
      nil -> {:error, :email_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_email_id}
    end
  end

  defp deliver_submission(submission, user_id, params, %DateTime{} = send_at) do
    if DateTime.compare(send_at, DateTime.utc_now()) == :gt do
      case SendEmailWorker.enqueue(user_id, params, nil,
             scheduled_for: send_at,
             submission_id: submission.id
           ) do
        {:ok, job} ->
          scheduled_status =
            %{
              "status" => "scheduled",
              "scheduledAt" => DateTime.to_iso8601(send_at)
            }
            |> maybe_put_job_id(job.id)

          case JMAP.update_submission(submission, %{
                 send_at: send_at,
                 undo_status: "pending",
                 delivery_status: scheduled_status
               }) do
            {:ok, updated_submission} -> {:ok, updated_submission}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          _ = JMAP.fail_submission(submission, reason)
          {:error, reason}
      end
    else
      case Sender.send_email(user_id, params) do
        {:ok, %{message_id: message_id, status: status}} ->
          delivery_status = %{"status" => status || "sent", "messageId" => message_id}

          case JMAP.finalize_submission(submission, delivery_status) do
            {:ok, updated_submission} -> {:ok, updated_submission}
            {:error, reason} -> {:error, reason}
          end

        {:ok, sent_message} ->
          delivery_status = %{
            "status" => "sent",
            "messageId" => sent_message.message_id,
            "sentEmailId" => to_string(sent_message.id)
          }

          case JMAP.finalize_submission(submission, delivery_status) do
            {:ok, updated_submission} -> {:ok, updated_submission}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          _ = JMAP.fail_submission(submission, reason)
          {:error, reason}
      end
    end
  end

  defp submission_message_params(message, fallback_from) do
    %{
      from: normalize_email_header(message.from || fallback_from || ""),
      to: message.to,
      cc: message.cc,
      bcc: message.bcc,
      subject: message.subject || "",
      text_body: message.text_body,
      html_body: message.html_body,
      in_reply_to: message.in_reply_to,
      references: message.references
    }
  end

  defp normalize_email_header(nil), do: nil

  defp normalize_email_header(value) do
    case Regex.run(~r/<([^>]+)>/, value) do
      [_, email] -> String.trim(email)
      _ -> String.trim(value)
    end
  end

  defp split_recipients(nil), do: []

  defp split_recipients(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_send_at(nil), do: {:ok, DateTime.utc_now()}
  defp parse_send_at(""), do: {:ok, DateTime.utc_now()}

  defp parse_send_at(value) do
    case DateTime.from_iso8601(value) do
      {:ok, send_at, _offset} -> {:ok, send_at}
      _ -> {:error, :invalid_send_at}
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
      "deliveryStatus" => public_delivery_status(submission.delivery_status)
    }
  end

  defp submission_error(:invalid_send_at), do: "sendAt must be a valid ISO 8601 datetime"
  defp submission_error(:email_not_found), do: "Email not found"
  defp submission_error(:invalid_email_id), do: "emailId must reference an existing Email"
  defp submission_error(:already_final), do: "Submission can no longer be canceled"
  defp submission_error(:too_late), do: "Submission has already reached its send time"
  defp submission_error(:invalid_submission_update), do: "Only undoStatus=canceled is supported"
  defp submission_error(reason), do: inspect(reason)

  defp handle_submission_update(update, mailbox) do
    Enum.reduce(update, {%{}, %{}}, fn {submission_id, changes}, {updated_acc, failed_acc} ->
      int_id = parse_email_id(submission_id)

      cond do
        is_nil(int_id) ->
          {updated_acc, Map.put(failed_acc, submission_id, %{"type" => "notFound"})}

        true ->
          case JMAP.get_submission(int_id, mailbox.id) do
            nil ->
              {updated_acc, Map.put(failed_acc, submission_id, %{"type" => "notFound"})}

            submission ->
              case apply_submission_changes(submission, changes) do
                {:ok, _updated_submission} ->
                  {Map.put(updated_acc, submission_id, nil), failed_acc}

                {:error, reason} ->
                  failure = %{
                    "type" => "invalidProperties",
                    "description" => submission_error(reason)
                  }

                  {updated_acc, Map.put(failed_acc, submission_id, failure)}
              end
          end
      end
    end)
  end

  defp apply_submission_changes(submission, changes) do
    changes = normalize_patch_object(changes)

    case Map.get(changes, "undoStatus") do
      "canceled" ->
        cancel_submission_job(submission)
        JMAP.cancel_submission(submission)

      nil ->
        {:error, :invalid_submission_update}

      _other ->
        {:error, :invalid_submission_update}
    end
  end

  defp ensure_submission_slot(mailbox_id, email_id) do
    case JMAP.get_submission_by_email(mailbox_id, email_id) do
      nil ->
        {:ok, :new}

      submission ->
        classify_submission_slot(submission)
    end
  end

  defp create_or_reuse_submission(
         {:reuse, submission},
         _mailbox,
         _message,
         _identity_id,
         _params,
         _send_at
       ),
       do: {:ok, submission}

  defp create_or_reuse_submission(
         {:resume, submission},
         _mailbox,
         _message,
         _identity_id,
         _params,
         _send_at
       ),
       do: {:ok, submission}

  defp create_or_reuse_submission(:new, mailbox, message, identity_id, params, send_at) do
    JMAP.create_submission(%{
      mailbox_id: mailbox.id,
      email_id: message.id,
      identity_id: identity_id,
      envelope_from: params.from,
      envelope_to: split_recipients(message.to),
      send_at: send_at,
      undo_status: "pending",
      delivery_status: %{"status" => "queued"}
    })
  end

  defp classify_submission_slot(submission) do
    status = Map.get(submission.delivery_status || %{}, "status")
    active_job = active_submission_job(submission.id)

    cond do
      submission.undo_status == "canceled" ->
        {:ok, {:reuse, submission}}

      submission.undo_status == "final" or status in ["sent", "failed"] ->
        {:ok, {:reuse, submission}}

      active_job ->
        {:ok, {:reuse, maybe_attach_job_id(submission, active_job)}}

      submission.undo_status == "pending" or status in ["queued", "pending", "scheduled"] ->
        {:ok, {:resume, submission}}

      true ->
        {:ok, :new}
    end
  end

  defp cancel_submission_job(submission) do
    case submission_job_id(submission) do
      job_id when is_integer(job_id) ->
        Oban.cancel_job(job_id)

      job_id when is_binary(job_id) ->
        case Integer.parse(job_id) do
          {int_id, ""} -> Oban.cancel_job(int_id)
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  defp active_submission_job(submission_id) when is_integer(submission_id) do
    Repo.one(
      from j in Job,
        where:
          j.worker == ^to_string(SendEmailWorker) and
            j.state in ^["available", "scheduled", "executing", "retryable"] and
            fragment("?->>'submission_id' = ?", j.args, ^to_string(submission_id)),
        order_by: [desc: j.inserted_at],
        limit: 1
    )
  end

  defp active_submission_job(_submission_id), do: nil

  defp maybe_attach_job_id(submission, %Job{id: job_id}) do
    delivery_status =
      submission.delivery_status
      |> Kernel.||(%{})
      |> Map.new()
      |> Map.put("jobId", job_id)

    case JMAP.update_submission(submission, %{delivery_status: delivery_status}) do
      {:ok, updated_submission} -> updated_submission
      {:error, _reason} -> %{submission | delivery_status: delivery_status}
    end
  end

  defp submission_job_id(submission) do
    case Map.get(submission.delivery_status || %{}, "jobId") do
      nil ->
        case active_submission_job(submission.id) do
          %Job{id: job_id} -> job_id
          _ -> nil
        end

      job_id ->
        job_id
    end
  end

  defp maybe_put_job_id(delivery_status, nil), do: delivery_status
  defp maybe_put_job_id(delivery_status, job_id), do: Map.put(delivery_status, "jobId", job_id)

  defp public_delivery_status(status) when is_map(status), do: Map.delete(status, "jobId")
  defp public_delivery_status(_status), do: %{}

  defp query_error({:unsupported_filter, filter_name}) do
    %{
      "type" => "unsupportedFilter",
      "description" => "Unsupported Email/query filter: #{filter_name}"
    }
  end

  defp query_error({:unsupported_sort, property}) do
    %{
      "type" => "unsupportedSort",
      "description" => "Unsupported Email/query sort property: #{property}"
    }
  end

  defp query_error({:invalid_filter_value, value}) do
    %{
      "type" => "invalidArguments",
      "description" => "Invalid Email/query filter value: #{inspect(value)}"
    }
  end

  defp query_error(:invalid_filter) do
    %{"type" => "invalidArguments", "description" => "Invalid Email/query filter"}
  end

  defp query_error(:invalid_sort) do
    %{"type" => "invalidArguments", "description" => "Invalid Email/query sort"}
  end

  defp query_error(reason) do
    %{"type" => "invalidArguments", "description" => inspect(reason)}
  end

  defp search_preview(message) do
    text = message.text_body || message.html_body || ""

    text
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> nil_if_blank()
    |> case do
      nil -> nil
      preview -> String.slice(preview, 0, 256)
    end
  end

  defp nil_if_blank(nil), do: nil

  defp nil_if_blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp nil_if_blank(value), do: value

  defp resolve_creation_ids(value, created_ids) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {key, resolve_creation_ids(nested_value, created_ids)}
    end)
  end

  defp resolve_creation_ids(value, created_ids) when is_list(value) do
    Enum.map(value, &resolve_creation_ids(&1, created_ids))
  end

  defp resolve_creation_ids("#" <> creation_id, created_ids) do
    Map.get(created_ids, creation_id, "#" <> creation_id)
  end

  defp resolve_creation_ids(value, _created_ids), do: value

  defp extract_created_ids(%{"created" => created}) when is_map(created) do
    Enum.reduce(created, %{}, fn {client_id, %{"id" => id}}, acc ->
      Map.put(acc, client_id, id)
    end)
  end

  defp extract_created_ids(_result), do: %{}

  defp maybe_put_created_ids(response, created_ids) when map_size(created_ids) > 0 do
    Map.put(response, "createdIds", created_ids)
  end

  defp maybe_put_created_ids(response, _created_ids), do: response

  defp normalize_patch_object(changes) when is_map(changes) do
    Enum.reduce(changes, %{}, fn
      {key, value}, acc when is_binary(key) ->
        if String.contains?(key, "/") do
          put_patch_value(acc, String.split(key, "/", trim: true), value)
        else
          Map.put(acc, key, value)
        end

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp normalize_patch_object(changes), do: changes

  defp put_patch_value(acc, [segment], value), do: Map.put(acc, segment, value)

  defp put_patch_value(acc, [segment | rest], value) do
    nested = Map.get(acc, segment, %{})
    Map.put(acc, segment, put_patch_value(nested, rest, value))
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
