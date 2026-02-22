defmodule Elektrine.Jobs.EmailRecategorizer do
  @moduledoc "Quantum job to recategorize emails that weren't properly categorized\n"
  require Logger
  alias Elektrine.Email
  alias Elektrine.Email.Message
  alias Elektrine.Repo
  import Ecto.Query
  @batch_size 50
  @batch_delay_ms 100
  def run do
    cutoff = DateTime.utc_now() |> DateTime.add(-1, :day)

    messages =
      from(m in Message,
        where: m.inserted_at > ^cutoff and not m.spam and not m.archived,
        order_by: [desc: m.inserted_at],
        limit: ^@batch_size
      )
      |> Repo.all(timeout: 5000)

    if messages != [] do
      Logger.info("EmailRecategorizer: Checking #{length(messages)} messages")

      recategorized =
        Enum.reduce(messages, 0, fn message, count ->
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
    e -> Logger.error("EmailRecategorizer error: #{inspect(e)}")
  end

  defp recategorize_message(message) do
    message_attrs = %{
      "subject" => message.subject || "",
      "from" => message.from || "",
      "to" => message.to || "",
      "text_body" => message.text_body || "",
      "html_body" => message.html_body || "",
      "metadata" => %{"headers" => (message.metadata && message.metadata["headers"]) || %{}}
    }

    categorized = Email.categorize_message(message_attrs)
    new_category = categorized["category"]

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
