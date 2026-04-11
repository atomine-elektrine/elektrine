defmodule Elektrine.ActivityPub.CollectionCountSyncWorker do
  @moduledoc """
  Fetches collection-backed like/reply counts for a cached remote message.
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 2,
    unique: [period: 300, keys: [:message_id], states: [:available, :scheduled, :executing]]

  import Ecto.Query

  alias Elektrine.ActivityPub.CollectionFetcher
  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

  def enqueue(message_id, post) when is_integer(message_id) and is_map(post) do
    %{
      "message_id" => message_id,
      "likes" => Map.get(post, "likes"),
      "replies" => Map.get(post, "replies"),
      "comments" => Map.get(post, "comments"),
      "replies_count" => Map.get(post, "repliesCount")
    }
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def enqueue(_, _), do: {:error, :invalid_collection_sync}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id} = args}) do
    like_count = fetch_collection_count(args["likes"])

    reply_count =
      [
        fetch_collection_count(args["replies"]),
        fetch_collection_count(args["comments"]),
        parse_non_negative_count(args["replies_count"])
      ]
      |> Enum.max(fn -> 0 end)

    if like_count > 0 || reply_count > 0 do
      Repo.update_all(
        from(m in Message,
          where: m.id == ^message_id,
          update: [
            set: [
              like_count: fragment("GREATEST(like_count, ?)", ^like_count),
              reply_count: fragment("GREATEST(reply_count, ?)", ^reply_count)
            ]
          ]
        ),
        []
      )
    end

    :ok
  end

  defp fetch_collection_count(nil), do: 0

  defp fetch_collection_count(value) when is_binary(value) or is_map(value) do
    case CollectionFetcher.fetch_collection_count(value) do
      {:ok, count} -> parse_non_negative_count(count)
      _ -> 0
    end
  end

  defp fetch_collection_count(_), do: 0

  defp parse_non_negative_count(value) when is_integer(value), do: max(value, 0)

  defp parse_non_negative_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> max(parsed, 0)
      :error -> 0
    end
  end

  defp parse_non_negative_count(_), do: 0
end
