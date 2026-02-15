defmodule Elektrine.Jobs.EmailRecategorizer do
  @moduledoc """
  Quantum job to recategorize emails that weren't properly categorized
  """

  require Logger
  alias Elektrine.Repo
  alias Elektrine.Email
  alias Elektrine.Email.Message
  import Ecto.Query

  # Process fewer messages to reduce DB load
  @batch_size 50
  # Delay between messages to avoid saturating pool
  @batch_delay_ms 100

  def run do
    try do
      # Only check messages from last 24 hours (not a full week)
      cutoff = DateTime.utc_now() |> DateTime.add(-1, :day)

      messages =
        from(m in Message,
          where: m.inserted_at > ^cutoff and not m.spam and not m.archived,
          order_by: [desc: m.inserted_at],
          limit: ^@batch_size
        )
        |> Repo.all(timeout: 5_000)

      if messages != [] do
        Logger.info("EmailRecategorizer: Checking #{length(messages)} messages")

        recategorized =
          Enum.reduce(messages, 0, fn message, count ->
            # Small delay between messages to avoid pool saturation
            Process.sleep(@batch_delay_ms)

            case recategorize_message(message) do
              {:ok, true} -> count + 1
              _ -> count
            end
          end)

        if recategorized > 0 do
          Logger.info("EmailRecategorizer: Recategorized #{recategorized} messages")
        end
      end
    rescue
      e ->
        Logger.error("EmailRecategorizer error: #{inspect(e)}")
    end
  end

  defp recategorize_message(message) do
    try do
      # Build message attributes for categorizer
      message_attrs = %{
        "subject" => message.subject || "",
        "from" => message.from || "",
        "to" => message.to || "",
        "text_body" => message.text_body || "",
        "html_body" => message.html_body || "",
        "metadata" => %{"headers" => (message.metadata && message.metadata["headers"]) || %{}}
      }

      # Run categorization
      categorized = Email.categorize_message(message_attrs)
      new_category = categorized["category"]

      # Only update if it should move out of inbox
      if new_category != "inbox" && new_category != message.category do
        message
        |> Ecto.Changeset.change(%{
          category: new_category,
          is_newsletter: categorized["is_newsletter"],
          is_receipt: categorized["is_receipt"],
          is_notification: categorized["is_notification"]
        })
        |> Repo.update()

        Logger.info(
          "Recategorized: '#{String.slice(message.subject || "No subject", 0, 50)}' from inbox -> #{new_category}"
        )

        {:ok, true}
      else
        {:ok, false}
      end
    rescue
      e ->
        Logger.error("Failed to recategorize message #{message.id}: #{inspect(e)}")
        {:error, e}
    end
  end
end
