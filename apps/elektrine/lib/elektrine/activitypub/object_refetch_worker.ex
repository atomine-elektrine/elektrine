defmodule Elektrine.ActivityPub.ObjectRefetchWorker do
  @moduledoc """
  Refetches a remote ActivityPub object and reinjects it through the normal handlers.

  This mirrors the Pleroma pattern of treating remote object refreshes as durable
  jobs instead of ad hoc request-time fetches.
  """

  use Oban.Worker,
    queue: :federation,
    max_attempts: 3,
    priority: 7,
    unique: [
      period: 900,
      keys: [:uri],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  require Logger

  alias Elektrine.ActivityPub.{Handler, Normalizer, RemoteFetch}
  alias Elektrine.Messaging

  @content_types ~w[Note Article Page Question Event Audio Video Image]

  def enqueue(uri, opts \\ [])

  def enqueue(uri, opts) when is_binary(uri) do
    %{"uri" => uri}
    |> new(opts)
    |> Elektrine.JobQueue.insert()
  end

  def enqueue(_uri, _opts), do: {:error, :invalid_uri}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"uri" => uri}}) do
    case RemoteFetch.fetch_object_uncached(uri) do
      {:ok, %{"type" => "Create"} = activity} ->
        reinject_activity(activity)

      {:ok, %{"type" => type} = object} when type in @content_types ->
        reinject_content_object(object)

      {:ok, %{"type" => type}} when type in ["Delete", "Update"] ->
        {:discard, :activity_not_refetchable}

      {:ok, _other} ->
        {:discard, :unsupported_object}

      {:error, reason} when reason in [:not_found, :object_id_mismatch, :unauthorized_fetch] ->
        {:discard, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reinject_activity(activity) do
    actor_uri = Normalizer.actor_ref_uri(activity["actor"]) || Normalizer.actor_uri(activity)

    if is_binary(actor_uri) do
      case Handler.process_activity_async(activity, actor_uri, nil) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:discard, :invalid_actor_uri}
    end
  end

  defp reinject_content_object(object) do
    actor_uri = Normalizer.actor_uri(object)

    cond do
      not is_binary(actor_uri) ->
        {:discard, :invalid_actor_uri}

      existing_message?(object) ->
        case Handler.refresh_remote_post(object, actor_uri) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end

      true ->
        case Handler.store_remote_post(object, actor_uri) do
          {:ok, _result} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp existing_message?(object) do
    refs =
      [object["id"], object["url"]]
      |> Enum.filter(&is_binary/1)

    Enum.any?(refs, &(Messaging.get_message_by_activitypub_ref(&1, cache: false) != nil))
  rescue
    error ->
      Logger.debug("Object refetch existing-message lookup failed: #{Exception.message(error)}")
      false
  end
end
