defmodule Elektrine.ActivityPub.SubmittedLinkRepairWorker do
  @moduledoc """
  Repairs missing submitted-link metadata for federated root posts.

  It re-fetches remote post objects and routes them through the normal
  ActivityPub update handler so `external_link` and `primary_url` can be
  persisted onto older local rows.
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 2,
    unique: [period: 300, keys: [:message_id], states: [:available, :scheduled, :executing]]

  import Ecto.Query

  alias Elektrine.Messaging.Message
  alias Elektrine.Repo

  @batch_size 100

  def enqueue_batch(limit \\ @batch_size) when is_integer(limit) and limit > 0 do
    %{"type" => "batch", "limit" => limit}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def enqueue_single(message_id) when is_integer(message_id) and message_id > 0 do
    %{"type" => "single", "message_id" => message_id}
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  def enqueue_single(_), do: {:error, :invalid_message_id}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"type" => "single", "message_id" => message_id}}) do
    case Repo.get(Message, message_id) |> Repo.preload(:remote_actor) do
      nil -> {:discard, :message_not_found}
      message -> repair_message(message)
    end
  end

  def perform(%Oban.Job{args: %{"type" => "batch", "limit" => limit}}) do
    candidate_messages(limit)
    |> Enum.each(&repair_message/1)

    :ok
  end

  def perform(%Oban.Job{}) do
    candidate_messages(@batch_size)
    |> Enum.each(&repair_message/1)

    :ok
  end

  defp candidate_messages(limit) do
    from(m in Message,
      where: m.federated == true,
      where: is_nil(m.deleted_at),
      where: is_nil(m.reply_to_id),
      where: not is_nil(m.remote_actor_id),
      where: not is_nil(m.activitypub_id),
      where: is_nil(m.primary_url),
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      preload: [:remote_actor]
    )
    |> Repo.all()
    |> Enum.filter(&missing_external_link?/1)
  end

  defp missing_external_link?(%Message{media_metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, "external_link") do
      url when is_binary(url) and url != "" -> false
      _ -> true
    end
  end

  defp missing_external_link?(_), do: true

  defp repair_message(%Message{activitypub_id: activitypub_id} = message)
       when is_binary(activitypub_id) do
    with {:ok, post_object} <- Elektrine.ActivityPub.Fetcher.fetch_object(activitypub_id),
         submitted_url when is_binary(submitted_url) <- extract_external_link(post_object) do
      metadata = Map.put(message.media_metadata || %{}, "external_link", submitted_url)

      Repo.update_all(
        from(m in Message, where: m.id == ^message.id),
        set: [
          primary_url: submitted_url,
          media_metadata: metadata,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        ]
      )

      :ok
    else
      _ -> :ok
    end
  end

  defp repair_message(_), do: :ok

  defp extract_external_link(object) when is_map(object) do
    activity_id = normalize_external_link_candidate(object["id"])

    [
      extract_attachment_link(object["attachment"]),
      extract_url_field_link(object["url"], activity_id),
      extract_source_field_link(object["source"], activity_id)
    ]
    |> Enum.find(&is_binary/1)
  end

  defp extract_external_link(_), do: nil

  defp extract_attachment_link(attachments) when is_list(attachments) do
    attachments
    |> Enum.find_value(fn
      %{"type" => "Link"} = att ->
        normalize_external_link_candidate(
          att["href"] || att["url"] || get_in(att, ["url", "href"])
        )

      %{} = att ->
        normalize_external_link_candidate(att["href"])

      _ ->
        nil
    end)
  end

  defp extract_attachment_link(%{} = attachment), do: extract_attachment_link([attachment])
  defp extract_attachment_link(_), do: nil

  defp extract_url_field_link(url_field, activity_id) do
    url_field
    |> expand_external_link_candidates()
    |> Enum.find(fn candidate -> is_binary(candidate) and candidate != activity_id end)
  end

  defp extract_source_field_link(%{} = source, activity_id) do
    [source["url"], source["href"], source["content"]]
    |> expand_external_link_candidates()
    |> Enum.find(fn candidate -> is_binary(candidate) and candidate != activity_id end)
  end

  defp extract_source_field_link(_, _), do: nil

  defp expand_external_link_candidates(value) when is_list(value),
    do: Enum.flat_map(value, &expand_external_link_candidates/1)

  defp expand_external_link_candidates(%{"href" => href}),
    do: expand_external_link_candidates(href)

  defp expand_external_link_candidates(%{"url" => url}), do: expand_external_link_candidates(url)
  defp expand_external_link_candidates(%{href: href}), do: expand_external_link_candidates(href)
  defp expand_external_link_candidates(%{url: url}), do: expand_external_link_candidates(url)

  defp expand_external_link_candidates(value) when is_binary(value) do
    case normalize_external_link_candidate(value) do
      normalized when is_binary(normalized) -> [normalized]
      _ -> []
    end
  end

  defp expand_external_link_candidates(_), do: []

  defp normalize_external_link_candidate(value) when is_binary(value) do
    case URI.parse(String.trim(value)) do
      %URI{scheme: scheme, host: host} = parsed
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        URI.to_string(parsed)

      _ ->
        nil
    end
  end

  defp normalize_external_link_candidate(_), do: nil
end
