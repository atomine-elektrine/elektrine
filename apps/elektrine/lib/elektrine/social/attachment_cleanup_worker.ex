defmodule Elektrine.Social.AttachmentCleanupWorker do
  @moduledoc """
  Deletes local upload objects that are no longer referenced by active messages.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    priority: 8,
    unique: [
      period: 3_600,
      keys: [:message_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Uploads

  def enqueue(message_id, media_urls, opts \\ [])

  def enqueue(message_id, media_urls, opts) when is_integer(message_id) and is_list(media_urls) do
    urls =
      media_urls
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    %{"message_id" => message_id, "media_urls" => urls}
    |> new(Keyword.put_new(opts, :schedule_in, 60))
    |> Elektrine.JobQueue.insert()
  end

  def enqueue(_message_id, _media_urls, _opts), do: {:error, :invalid_cleanup_args}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id, "media_urls" => media_urls}})
      when is_list(media_urls) do
    media_urls
    |> Enum.filter(&local_upload?/1)
    |> Enum.reject(&referenced_by_active_message?(&1, message_id))
    |> Enum.each(&Uploads.delete_uploaded_file/1)

    :ok
  end

  defp referenced_by_active_message?(url, deleted_message_id) do
    Repo.exists?(
      from m in Message,
        where: m.id != ^deleted_message_id,
        where: is_nil(m.deleted_at),
        where: fragment("? && ?", m.media_urls, ^[url])
    )
  end

  defp local_upload?("/uploads/" <> _), do: true
  defp local_upload?("chat-attachments/" <> _), do: true
  defp local_upload?("timeline-attachments/" <> _), do: true
  defp local_upload?("discussion-attachments/" <> _), do: true
  defp local_upload?("gallery-attachments/" <> _), do: true
  defp local_upload?("voice-messages/" <> _), do: true
  defp local_upload?(_), do: false
end
