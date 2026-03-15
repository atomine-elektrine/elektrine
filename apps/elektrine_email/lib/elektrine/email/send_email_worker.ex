defmodule Elektrine.Email.SendEmailWorker do
  @moduledoc """
  Oban worker for sending emails in the background.

  Replaces the old EmailSendWorker GenServer with guaranteed delivery
  and automatic retries.
  """

  use Oban.Worker,
    queue: :email,
    max_attempts: 5,
    unique: [period: 300, fields: [:args], keys: [:email_id]]

  require Logger

  alias Elektrine.Email.Sender
  alias Elektrine.JMAP

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    user_id = args["user_id"]
    email_attrs = atomize_keys(args["email_attrs"])
    attachments = if args["attachments"], do: atomize_keys(args["attachments"]), else: nil
    submission = load_submission(args["submission_id"])

    Logger.info("SendEmailWorker processing email for user #{user_id}")

    case maybe_send_email(submission, user_id, email_attrs, attachments) do
      {:ok, result} ->
        Logger.info("Email sent successfully for user #{user_id}")
        reconcile_submission_success(submission, result)

        # Update user storage after successful send
        Elektrine.Accounts.Storage.update_user_storage(user_id)
        :ok

      {:skip, reason} ->
        Logger.info("SendEmailWorker skipped email for user #{user_id}: #{reason}")
        :ok

      {:error, :rate_limit_exceeded} ->
        # Snooze for 60 seconds on rate limit
        {:snooze, 60}

      {:error, reason} ->
        Logger.error("Email send failed for user #{user_id}: #{inspect(reason)}")
        reconcile_submission_failure(submission, reason)
        {:error, reason}
    end
  end

  @doc """
  Queue an email to be sent in the background.

  Options:
    - :scheduled_for - DateTime to schedule the email for later
  """
  def enqueue(user_id, email_attrs, attachments \\ nil, opts \\ []) do
    scheduled_for = Keyword.get(opts, :scheduled_for)
    submission_id = Keyword.get(opts, :submission_id)

    args =
      %{
        "user_id" => user_id,
        "email_attrs" => stringify_keys(email_attrs),
        "attachments" => if(attachments, do: stringify_keys(attachments), else: nil),
        "email_id" => enqueue_dedup_key(submission_id)
      }
      |> maybe_put_submission_id(submission_id)

    job_opts =
      if scheduled_for do
        [scheduled_at: scheduled_for]
      else
        []
      end

    args
    |> new(job_opts)
    |> Elektrine.JobQueue.insert()
  end

  # Convert atom keys to strings for JSON storage
  defp stringify_keys(nil), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  # Convert string keys back to atoms for Sender compatibility
  # Allowlist of valid keys for email sending to prevent atom exhaustion DoS
  @valid_email_keys ~w(
    to from cc bcc subject text_body html_body reply_to message_id in_reply_to
    references attachments headers priority content_type charset
    mailbox_id user_id scheduled_at expires_at list_id
  )

  defp atomize_keys(nil), do: nil

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) ->
        if k in @valid_email_keys do
          {String.to_existing_atom(k), atomize_keys(v)}
        else
          # Skip unknown keys instead of creating atoms
          {k, atomize_keys(v)}
        end

      {k, v} when is_atom(k) ->
        {k, atomize_keys(v)}
    end)
  end

  defp atomize_keys(list) when is_list(list), do: Enum.map(list, &atomize_keys/1)
  defp atomize_keys(value), do: value

  defp maybe_send_email(%{undo_status: "canceled"}, _user_id, _email_attrs, _attachments),
    do: {:skip, "submission canceled"}

  defp maybe_send_email(%{undo_status: "final"}, _user_id, _email_attrs, _attachments),
    do: {:skip, "submission already finalized"}

  defp maybe_send_email(:none, user_id, email_attrs, attachments) do
    Sender.send_email(user_id, email_attrs, attachments)
  end

  defp maybe_send_email(nil, _user_id, _email_attrs, _attachments),
    do: {:skip, "submission missing"}

  defp maybe_send_email(_submission, user_id, email_attrs, attachments) do
    Sender.send_email(user_id, email_attrs, attachments)
  end

  defp load_submission(nil), do: :none

  defp load_submission(submission_id) when is_integer(submission_id) do
    JMAP.get_submission(submission_id)
  end

  defp load_submission(submission_id) when is_binary(submission_id) do
    case Integer.parse(submission_id) do
      {int_id, ""} -> JMAP.get_submission(int_id)
      _ -> :none
    end
  end

  defp load_submission(_submission_id), do: :none

  defp reconcile_submission_success(:none, _result), do: :ok
  defp reconcile_submission_success(nil, _result), do: :ok

  defp reconcile_submission_success(submission, result) when is_map(result) do
    delivery_status =
      %{
        "status" => result_field(result, :status) || "sent",
        "messageId" => result_field(result, :message_id)
      }
      |> maybe_put_sent_email_id(result_field(result, :id))

    JMAP.finalize_submission(submission, delivery_status)

    :ok
  end

  defp reconcile_submission_success(submission, _result) do
    JMAP.finalize_submission(submission)
    :ok
  end

  defp reconcile_submission_failure(:none, _reason), do: :ok
  defp reconcile_submission_failure(nil, _reason), do: :ok

  defp reconcile_submission_failure(submission, reason) do
    JMAP.fail_submission(submission, reason)
    :ok
  end

  defp maybe_put_submission_id(args, submission_id) when is_integer(submission_id) do
    Map.put(args, "submission_id", submission_id)
  end

  defp maybe_put_submission_id(args, submission_id) when is_binary(submission_id) do
    Map.put(args, "submission_id", submission_id)
  end

  defp maybe_put_submission_id(args, _submission_id), do: args

  defp enqueue_dedup_key(submission_id) when is_integer(submission_id),
    do: "submission:#{submission_id}"

  defp enqueue_dedup_key(submission_id) when is_binary(submission_id),
    do: "submission:#{submission_id}"

  defp enqueue_dedup_key(_submission_id), do: Ecto.UUID.generate()

  defp maybe_put_sent_email_id(delivery_status, nil), do: delivery_status

  defp maybe_put_sent_email_id(delivery_status, sent_email_id) do
    Map.put(delivery_status, "sentEmailId", to_string(sent_email_id))
  end

  defp result_field(result, key) when is_atom(key) do
    cond do
      is_map(result) and Map.has_key?(result, key) ->
        Map.get(result, key)

      is_map(result) and Map.has_key?(result, Atom.to_string(key)) ->
        Map.get(result, Atom.to_string(key))

      match?(%_{}, result) ->
        Map.get(result, key)

      true ->
        nil
    end
  end
end
