defmodule Elektrine.Social.FetchLinkPreviewWorker do
  @moduledoc """
  Oban worker for fetching link preview metadata.

  Replaces the old LinkPreviewWorker GenServer with guaranteed delivery
  and automatic retries.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 3600, fields: [:args], keys: [:url]]

  require Logger

  alias Elektrine.Social.LinkPreview
  alias Elektrine.Social.LinkPreviewFetcher
  alias Elektrine.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"url" => url} = args}) do
    message_id = args["message_id"]

    Logger.info("FetchLinkPreviewWorker processing URL: #{url}")

    # Fetch the metadata
    metadata = LinkPreviewFetcher.fetch_preview_metadata(url)

    # Find or create the preview record
    preview = find_or_create_preview(url, metadata)

    if preview && metadata[:status] == "success" do
      Logger.info("Link preview fetched successfully for: #{url}")

      # Broadcast update if there's an associated message
      if message_id do
        Phoenix.PubSub.broadcast(
          Elektrine.PubSub,
          "message:#{message_id}",
          {:link_preview_ready, message_id, preview}
        )
      end

      :ok
    else
      error = metadata[:error_message] || "Unknown error"
      Logger.warning("Link preview fetch failed for #{url}: #{error}")
      {:error, error}
    end
  end

  @doc """
  Queue a URL for link preview fetching.

  Returns {:ok, job} or {:ok, :exists} if preview already exists.
  """
  def enqueue(url, message_id \\ nil) do
    # Check if preview already exists and is complete
    case Repo.get_by(LinkPreview, url: url) do
      %LinkPreview{status: "success"} = preview ->
        {:ok, {:exists, preview}}

      _ ->
        # Ensure we have a pending preview record
        ensure_pending_preview(url)

        args = %{
          "url" => url,
          "message_id" => message_id
        }

        args
        |> new()
        |> Oban.insert()
    end
  end

  @doc """
  Queue multiple URLs for link preview fetching.
  """
  def enqueue_many(urls, message_id \\ nil) when is_list(urls) do
    Enum.map(urls, fn url -> enqueue(url, message_id) end)
  end

  defp ensure_pending_preview(url) do
    case Repo.get_by(LinkPreview, url: url) do
      nil ->
        %LinkPreview{}
        |> LinkPreview.changeset(%{url: url, status: "pending"})
        |> Repo.insert()

      existing ->
        {:ok, existing}
    end
  end

  defp find_or_create_preview(url, metadata) do
    case Repo.get_by(LinkPreview, url: url) do
      nil ->
        case %LinkPreview{}
             |> LinkPreview.changeset(Map.put(metadata, :url, url))
             |> Repo.insert() do
          {:ok, p} -> p
          {:error, _} -> Repo.get_by(LinkPreview, url: url)
        end

      existing ->
        case LinkPreviewFetcher.update_preview_with_metadata(existing, metadata) do
          {:ok, p} -> p
          {:error, _} -> existing
        end
    end
  end
end
