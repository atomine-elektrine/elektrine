defmodule Elektrine.ActivityPub.SignatureRetryWorker do
  @moduledoc """
  Retries ActivityPub inbox payloads that failed HTTP signature validation.

  Some remote servers rotate or repair actor keys after our first validation
  attempt. This worker preserves the signed request metadata, refetches through
  the normal verifier, and only enqueues the activity if the signature actor
  matches the payload actor.
  """

  use Oban.Worker,
    queue: :activitypub,
    max_attempts: 5,
    unique: [period: 300, fields: [:args], keys: [:activity_id, :actor_uri]]

  require Logger

  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.HTTPSignature
  alias Elektrine.ActivityPub.ProcessActivityWorker

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "activity" => activity,
            "actor_uri" => actor_uri,
            "method" => method,
            "req_headers" => req_headers,
            "request_path" => request_path,
            "query_string" => query_string
          } = args
      })
      when is_map(activity) and is_binary(actor_uri) and is_list(req_headers) do
    with {:ok, headers} <- normalize_headers(req_headers),
         {:ok, signature_header} <- signature_header(headers),
         :ok <- actor_matches_payload?(activity, actor_uri),
         {:ok, ^actor_uri} <-
           verify_preserved_request(method, request_path, query_string, headers, signature_header),
         :ok <- maybe_domain_deliverable(actor_uri),
         {:ok, _job_or_duplicate} <-
           ProcessActivityWorker.enqueue(activity, actor_uri, target_user_from_args(args)) do
      :ok
    else
      {:error, reason} when reason in [:invalid_metadata, :missing_signature, :actor_mismatch] ->
        {:discard, reason}

      {:error, reason} ->
        Logger.warning(
          "Signature retry failed for #{inspect(activity["id"])} from #{actor_uri}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_metadata}

  @doc """
  Enqueues a retry when the signature failure looks transient (key or actor fetch).

  Never raises; a failure to enqueue only loses the retry, not the request.
  """
  def enqueue_if_retryable(activity, actor_uri, conn, target_user, reason) do
    if retryable_error?(reason) do
      _ = enqueue(activity, actor_uri, conn, target_user)
    end

    :ok
  rescue
    e ->
      Logger.warning("Failed to enqueue signature retry: #{inspect(e)}")
      :ok
  end

  def retryable_error?({:key_fetch_failed, _}), do: true
  def retryable_error?(:invalid_signature), do: true
  def retryable_error?(:actor_fetch_failed), do: true
  def retryable_error?(_), do: false

  def enqueue(activity, actor_uri, conn, target_user \\ nil)
      when is_map(activity) and is_binary(actor_uri) do
    args = %{
      "activity" => activity,
      "activity_id" => activity["id"],
      "actor_uri" => actor_uri,
      "method" => conn.method,
      "req_headers" => json_safe_headers(conn.req_headers),
      "request_path" => conn.request_path,
      "query_string" => conn.query_string || "",
      "target_user_id" => target_user && target_user.id
    }

    args
    |> new()
    |> Elektrine.JobQueue.insert()
  end

  defp json_safe_headers(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {key, value} when is_binary(key) and is_binary(value) -> [[key, value]]
      [key, value] when is_binary(key) and is_binary(value) -> [[key, value]]
      _ -> []
    end)
  end

  defp json_safe_headers(_headers), do: []

  defp normalize_headers(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      {key, value}, {:ok, acc} when is_binary(key) and is_binary(value) ->
        {:cont, {:ok, [{String.downcase(key), value} | acc]}}

      [key, value], {:ok, acc} when is_binary(key) and is_binary(value) ->
        {:cont, {:ok, [{String.downcase(key), value} | acc]}}

      _, _ ->
        {:halt, {:error, :invalid_metadata}}
    end)
  end

  defp signature_header(headers) do
    case List.keyfind(headers, "signature", 0) do
      {"signature", value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_signature}
    end
  end

  defp actor_matches_payload?(%{"actor" => actor}, actor) when is_binary(actor), do: :ok
  defp actor_matches_payload?(_activity, _actor_uri), do: {:error, :actor_mismatch}

  defp verify_preserved_request(method, request_path, query_string, headers, signature_header) do
    conn = %Plug.Conn{
      method: method || "POST",
      request_path: request_path || "/inbox",
      query_string: query_string || "",
      req_headers: headers
    }

    HTTPSignature.verify(conn, signature_header)
  end

  defp target_user_from_args(%{"target_user_id" => user_id}) when is_integer(user_id) do
    Elektrine.Repo.get(Elektrine.Accounts.User, user_id)
  end

  defp target_user_from_args(_), do: nil

  defp maybe_domain_deliverable(actor_uri) do
    if ActivityPub.DomainDeliveryHealth.deliverable_url?(actor_uri) do
      :ok
    else
      {:error, :domain_unreachable}
    end
  end
end
