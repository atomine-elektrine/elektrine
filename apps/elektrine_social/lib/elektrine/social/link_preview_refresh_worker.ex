defmodule Elektrine.Social.LinkPreviewRefreshWorker do
  @moduledoc """
  Revalidates stale successful link previews in bounded batches.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: 3600, fields: [:worker]]

  import Ecto.Query

  require Logger

  alias Elektrine.Repo
  alias Elektrine.Social.{LinkPreview, LinkPreviewFetcher}

  @default_limit 100
  @default_max_age_days 7

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    limit = parse_int(args["limit"], @default_limit)
    max_age_days = parse_int(args["max_age_days"], @default_max_age_days)

    refreshed =
      [limit: limit, max_age_days: max_age_days]
      |> stale_previews()
      |> Enum.reduce(0, fn preview, count ->
        case refresh_preview(preview) do
          {:ok, _preview} -> count + 1
          {:error, _reason} -> count
        end
      end)

    Logger.info("Refreshed #{refreshed} stale link previews")
    :ok
  end

  def enqueue(opts \\ []) do
    %{
      "limit" => Keyword.get(opts, :limit, @default_limit),
      "max_age_days" => Keyword.get(opts, :max_age_days, @default_max_age_days)
    }
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def stale_previews(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    max_age_days = Keyword.get(opts, :max_age_days, @default_max_age_days)

    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-max_age_days * 86_400, :second)
      |> DateTime.truncate(:second)

    from(preview in LinkPreview,
      where: preview.status == "success",
      where: is_nil(preview.fetched_at) or preview.fetched_at < ^cutoff,
      order_by: [asc: preview.fetched_at, asc: preview.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  defp refresh_preview(%LinkPreview{} = preview) do
    metadata = LinkPreviewFetcher.fetch_preview_metadata(preview.url)

    case LinkPreviewFetcher.update_preview_with_metadata(preview, metadata) do
      {:ok, updated} ->
        {:ok, updated}

      {:error, changeset} ->
        Logger.warning(
          "Failed to refresh link preview #{preview.id}: #{inspect(changeset.errors)}"
        )

        {:error, :update_failed}
    end
  end

  defp parse_int(value, _default) when is_integer(value) and value > 0, do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp parse_int(_, default), do: default
end
