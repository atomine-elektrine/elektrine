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

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    user_id = args["user_id"]
    email_attrs = atomize_keys(args["email_attrs"])
    attachments = if args["attachments"], do: atomize_keys(args["attachments"]), else: nil

    Logger.info("SendEmailWorker processing email for user #{user_id}")

    case Sender.send_email(user_id, email_attrs, attachments) do
      {:ok, _result} ->
        Logger.info("Email sent successfully for user #{user_id}")
        # Update user storage after successful send
        Elektrine.Accounts.Storage.update_user_storage(user_id)
        :ok

      {:error, :rate_limit_exceeded} ->
        # Snooze for 60 seconds on rate limit
        {:snooze, 60}

      {:error, reason} ->
        Logger.error("Email send failed for user #{user_id}: #{inspect(reason)}")
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

    args = %{
      "user_id" => user_id,
      "email_attrs" => stringify_keys(email_attrs),
      "attachments" => if(attachments, do: stringify_keys(attachments), else: nil),
      "email_id" => Ecto.UUID.generate()
    }

    job_opts =
      if scheduled_for do
        [scheduled_at: scheduled_for]
      else
        []
      end

    args
    |> new(job_opts)
    |> Oban.insert()
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
    mailbox_id user_id scheduled_at expires_at
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
end
