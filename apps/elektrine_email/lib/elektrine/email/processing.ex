defmodule Elektrine.Email.Processing do
  @moduledoc """
  Email processing and categorization.
  Handles automatic message categorization and batch processing operations.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Elektrine.Repo
  alias Elektrine.Email.Message

  @doc """
  Categorizes an incoming message based on content analysis.
  """
  def categorize_message(message_attrs) do
    # Delegate to the new sophisticated categorizer
    Elektrine.Email.Categorizer.categorize_message(message_attrs)
  end

  @doc """
  Processes uncategorized messages (those without a category or with default 'inbox' category).
  This runs as a scheduled job to automatically categorize newly received emails.
  """
  def process_uncategorized_messages do
    Logger.info("Starting batch categorization of uncategorized emails")

    # Find messages that haven't been categorized yet or are in default 'inbox' category
    # but might belong elsewhere based on content analysis
    uncategorized_messages =
      Message
      |> where([m], is_nil(m.category) or m.category == "inbox")
      |> where([m], not m.spam and not m.archived)
      |> where([m], m.status != "sent" or is_nil(m.status))
      |> where([m], not is_nil(m.from) and not is_nil(m.subject))
      # Only process messages from last 7 days
      |> where([m], m.inserted_at > ^DateTime.add(DateTime.utc_now(), -7, :day))
      |> order_by(desc: :inserted_at)
      # Process in batches of 100
      |> limit(100)
      |> Repo.all()

    if Enum.empty?(uncategorized_messages) do
      Logger.info("No uncategorized messages found to process")
      {:ok, 0, 0}
    else
      Logger.info("Found #{length(uncategorized_messages)} uncategorized messages to process")

      {processed, changed} =
        Enum.reduce(uncategorized_messages, {0, 0}, fn message, {proc_acc, changed_acc} ->
          try do
            # Convert message to attributes map for categorizer
            message_attrs = %{
              "subject" => message.subject,
              "from" => message.from,
              "to" => message.to,
              "text_body" => message.text_body,
              "html_body" => message.html_body,
              "metadata" => message.metadata || %{}
            }

            # Apply categorization
            categorized_attrs = Elektrine.Email.Categorizer.categorize_message(message_attrs)
            new_category = categorized_attrs["category"]

            # Only update if category actually changed
            if new_category && new_category != message.category do
              changeset =
                message
                |> Ecto.Changeset.change(%{
                  category: new_category,
                  is_receipt: categorized_attrs["is_receipt"] || false,
                  is_newsletter: categorized_attrs["is_newsletter"] || false,
                  is_notification: categorized_attrs["is_notification"] || false
                })

              case Repo.update(changeset) do
                {:ok, _updated_message} ->
                  {proc_acc + 1, changed_acc + 1}

                {:error, _reason} ->
                  Logger.warning("Failed to update message #{message.id}")
                  {proc_acc + 1, changed_acc}
              end
            else
              {proc_acc + 1, changed_acc}
            end
          rescue
            e ->
              Logger.error("Error processing message #{message.id}: #{inspect(e)}")
              {proc_acc + 1, changed_acc}
          end
        end)

      Logger.info("Batch categorization completed: #{processed} processed, #{changed} updated")

      # Clear cache if any messages were updated
      if changed > 0 do
        Elektrine.Email.Cache.clear_all()
      end

      {:ok, processed, changed}
    end
  end

  @doc """
  Re-categorizes existing messages in a mailbox based on current categorization rules.
  """
  def recategorize_messages(mailbox_id) do
    messages =
      Message
      |> where(mailbox_id: ^mailbox_id)
      |> where([m], not m.spam)
      |> Repo.all()

    processed = length(messages)

    changed =
      Enum.count(messages, fn message ->
        # Create attrs map similar to what's used during message creation
        message_attrs = %{
          "subject" => message.subject || "",
          "from" => message.from || "",
          "to" => message.to || "",
          "text_body" => message.text_body || "",
          "html_body" => message.html_body || "",
          "metadata" => message.metadata || %{}
        }

        # Apply categorization
        categorized_attrs = categorize_message(message_attrs)

        # Check if anything would change
        would_change_category = categorized_attrs["category"] != message.category

        would_change_receipt =
          Map.get(categorized_attrs, "is_receipt", false) != message.is_receipt

        would_change_newsletter =
          Map.get(categorized_attrs, "is_newsletter", false) != message.is_newsletter

        would_change_notification =
          Map.get(categorized_attrs, "is_notification", false) != message.is_notification

        if would_change_category or would_change_receipt or would_change_newsletter or
             would_change_notification do
          # Extract only the categorization fields
          update_attrs =
            %{}
            |> maybe_put(:category, categorized_attrs["category"])
            |> maybe_put(:is_receipt, categorized_attrs["is_receipt"])
            |> maybe_put(:is_newsletter, categorized_attrs["is_newsletter"])
            |> maybe_put(:is_notification, categorized_attrs["is_notification"])

          # Update the message
          message
          |> Message.changeset(update_attrs)
          |> Repo.update()

          true
        else
          false
        end
      end)

    {processed, changed}
  end

  # Helper function to conditionally put values in a map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
