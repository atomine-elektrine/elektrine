defmodule Elektrine.ActivityPub.RequestReplayCache do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Elektrine.ActivityPub.RequestReplay
  alias Elektrine.ActivityPub.SigningKey
  alias Elektrine.Repo

  @default_signature_max_age_seconds 300
  @default_signature_clock_skew_seconds 300

  def claim(
        %Plug.Conn{} = conn,
        %SigningKey{} = signing_key,
        headers_list,
        signature_params,
        signature
      )
      when is_list(headers_list) and is_map(signature_params) and is_binary(signature) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    expires_at = DateTime.add(now, replay_ttl_seconds(), :second)
    digest = request_digest(conn)
    timestamp = signature_timestamp(conn, signature_params)

    attrs = %{
      nonce: replay_nonce(conn, signing_key, headers_list, signature_params, signature, digest),
      key_id: signing_key.key_id,
      actor_uri: actor_uri(signing_key),
      http_method: conn.method,
      request_path: conn.request_path,
      query_string: conn.query_string,
      signature_timestamp: timestamp,
      digest: digest,
      seen_at: now,
      expires_at: expires_at,
      inserted_at: now
    }

    case Repo.insert_all(RequestReplay, [attrs],
           on_conflict: :nothing,
           conflict_target: :nonce
         ) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :replayed_request}
    end
  end

  def claim(_, _, _, _, _), do: {:error, :invalid_replay_claim}

  def prune_expired(now \\ DateTime.utc_now()) do
    {count, _rows} =
      RequestReplay
      |> where([replay], replay.expires_at < ^DateTime.truncate(now, :second))
      |> Repo.delete_all()

    count
  end

  defp replay_nonce(conn, signing_key, headers_list, signature_params, signature, digest) do
    %{
      version: 1,
      key_id: signing_key.key_id,
      method: conn.method,
      path: conn.request_path,
      query: conn.query_string || "",
      host: host_header(conn),
      signed_headers: headers_list,
      created: Map.get(signature_params, "created"),
      expires: Map.get(signature_params, "expires"),
      date: List.first(Plug.Conn.get_req_header(conn, "date")),
      digest: digest,
      signature: signature
    }
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp host_header(conn) do
    conn
    |> Plug.Conn.get_req_header("host")
    |> List.first()
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> conn.host
    end
  end

  defp request_digest(conn) do
    conn
    |> Plug.Conn.get_req_header("digest")
    |> List.first()
  end

  defp signature_timestamp(conn, signature_params) do
    Map.get(signature_params, "created") || Map.get(signature_params, "expires") ||
      List.first(Plug.Conn.get_req_header(conn, "date"))
  end

  defp actor_uri(%SigningKey{key_id: key_id}) when is_binary(key_id) do
    key_id |> String.split("#") |> List.first()
  end

  defp actor_uri(_), do: nil

  defp replay_ttl_seconds do
    max_age =
      Application.get_env(:elektrine, :activitypub, [])
      |> Keyword.get(:signature_max_age_seconds, @default_signature_max_age_seconds)

    skew =
      Application.get_env(:elektrine, :activitypub, [])
      |> Keyword.get(:signature_clock_skew_seconds, @default_signature_clock_skew_seconds)

    max_age + skew
  end
end
