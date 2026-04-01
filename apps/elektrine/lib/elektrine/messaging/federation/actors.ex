defmodule Elektrine.Messaging.Federation.Actors do
  @moduledoc false

  alias Elektrine.ActivityPub.Actor, as: ActivityPubActor
  alias Elektrine.Repo

  def resolve_remote_actor_id(%{"uri" => uri}) when is_binary(uri) do
    case Repo.get_by(ActivityPubActor, uri: uri) do
      %ActivityPubActor{id: actor_id} ->
        {:ok, actor_id}

      nil ->
        {:error, :actor_not_found}
    end
  end

  def resolve_remote_actor_id(_actor_payload), do: {:error, :invalid_actor}

  def resolve_or_create_remote_actor_id(actor_payload, remote_domain, context)
      when is_map(actor_payload) and is_binary(remote_domain) and is_map(context) do
    case resolve_remote_actor_id(actor_payload) do
      {:ok, actor_id} ->
        {:ok, actor_id}

      _ ->
        upsert_remote_actor(actor_payload, remote_domain, context)
    end
  end

  def resolve_or_create_remote_actor_id(_actor_payload, _remote_domain, _context),
    do: {:error, :invalid_actor}

  def upsert_remote_actor(actor_payload, remote_domain, context)
      when is_map(actor_payload) and is_binary(remote_domain) and is_map(context) do
    normalized_remote_domain = String.downcase(remote_domain)

    case normalize_canonical_actor_payload(actor_payload, normalized_remote_domain) do
      {:ok, actor_identity} ->
        attrs = %{
          uri: actor_identity.uri,
          username: actor_identity.username,
          domain: actor_identity.domain,
          display_name: actor_identity.display_name,
          avatar_url: actor_identity.avatar_url,
          inbox_url: actor_identity.inbox_url,
          public_key: remote_actor_public_key(actor_payload, normalized_remote_domain, context),
          actor_type: "Person"
        }

        case Repo.get_by(ActivityPubActor, uri: actor_identity.uri) do
          %ActivityPubActor{id: actor_id} = actor ->
            _ = actor |> ActivityPubActor.changeset(attrs) |> Repo.update()
            {:ok, actor_id}

          nil ->
            case %ActivityPubActor{} |> ActivityPubActor.changeset(attrs) |> Repo.insert() do
              {:ok, actor} -> {:ok, actor.id}
              {:error, _} -> {:error, :invalid_actor}
            end
        end

      _ ->
        {:error, :invalid_actor}
    end
  end

  def upsert_remote_actor(_actor_payload, _remote_domain, _context), do: {:error, :invalid_actor}

  defp remote_actor_public_key(actor_payload, remote_domain, context)
       when is_map(actor_payload) and is_binary(remote_domain) do
    explicit_key =
      normalize_optional_string(
        actor_payload["public_key"] ||
          actor_payload["public_key_pem"] ||
          get_in(actor_payload, ["publicKey", "publicKeyPem"]) ||
          get_in(actor_payload, ["public_key", "public_key_pem"])
      )

    explicit_key ||
      call(context, :resolve_peer, [remote_domain])
      |> peer_actor_public_key(actor_payload, context)
  end

  defp remote_actor_public_key(_actor_payload, _remote_domain, _context), do: nil

  defp peer_actor_public_key(%{} = peer, actor_payload, context) when is_map(actor_payload) do
    actor_key_id =
      normalize_optional_string(
        actor_payload["key_id"] ||
          actor_payload[:key_id] ||
          get_in(actor_payload, ["publicKey", "id"])
      )

    peer
    |> then(&call(context, :incoming_verification_materials_for_key_id, [&1, actor_key_id]))
    |> List.first()
    |> encode_actor_public_key()
  end

  defp peer_actor_public_key(_peer, _actor_payload, _context), do: nil

  defp encode_actor_public_key(key) when is_binary(key) and byte_size(key) == 32 do
    Base.url_encode64(key, padding: false)
  end

  defp encode_actor_public_key(key) when is_binary(key) do
    normalize_optional_string(key)
  end

  defp encode_actor_public_key(_key), do: nil

  defp normalize_canonical_actor_payload(actor_payload, fallback_domain)
       when is_map(actor_payload) and is_binary(fallback_domain) do
    with {:ok, actor} <- normalize_dm_actor_payload(actor_payload, fallback_domain),
         uri when is_binary(uri) <-
           normalize_optional_string(actor_payload["uri"] || actor_payload[:uri]),
         true <- valid_absolute_http_uri?(uri),
         true <- canonical_actor_handle?(actor.username, actor.domain, actor.handle),
         inbox_url when is_binary(inbox_url) <- canonical_actor_inbox_url(actor_payload, uri) do
      {:ok,
       %{
         uri: uri,
         username: actor.username,
         domain: actor.domain,
         handle: actor.handle,
         display_name: actor.display_name,
         avatar_url: actor.avatar_url,
         inbox_url: inbox_url
       }}
    else
      false ->
        {:error, :invalid_actor}

      _ ->
        {:error, :invalid_actor}
    end
  end

  defp normalize_canonical_actor_payload(_actor_payload, _fallback_domain),
    do: {:error, :invalid_actor}

  defp normalize_dm_actor_payload(payload, fallback_domain)
       when is_map(payload) and is_binary(fallback_domain) do
    normalized_fallback_domain = String.downcase(fallback_domain)
    raw_uri = normalize_optional_string(payload["uri"] || payload[:uri])
    raw_handle = normalize_optional_string(payload["handle"] || payload[:handle])
    raw_username = normalize_optional_string(payload["username"] || payload[:username])
    raw_domain = normalize_optional_string(payload["domain"] || payload[:domain])

    normalized_identity =
      cond do
        is_binary(raw_handle) ->
          normalize_remote_dm_handle(raw_handle)

        is_binary(raw_username) ->
          domain = raw_domain || normalized_fallback_domain
          normalize_remote_dm_handle("#{raw_username}@#{domain}")

        true ->
          {:error, :invalid_event_payload}
      end

    with {:ok, identity} <- normalized_identity,
         true <- valid_absolute_http_uri?(raw_uri) do
      {:ok,
       %{
         uri: raw_uri,
         username: identity.username,
         domain: identity.domain,
         handle: identity.handle,
         display_name:
           normalize_optional_string(payload["display_name"] || payload[:display_name]) ||
             identity.username,
         avatar_url:
           normalize_optional_string(
             payload["avatar_url"] || payload[:avatar_url] || payload["avatar"] ||
               payload[:avatar]
           )
       }}
    else
      false ->
        {:error, :invalid_event_payload}

      error ->
        error
    end
  end

  defp normalize_dm_actor_payload(_payload, _fallback_domain),
    do: {:error, :invalid_event_payload}

  defp normalize_remote_dm_handle(handle) when is_binary(handle) do
    normalized =
      handle
      |> String.trim()
      |> String.trim_leading("@")
      |> String.downcase()

    case Regex.run(~r/^([a-z0-9][a-z0-9_.-]{0,63})@([a-z0-9.-]+\.[a-z]{2,})$/, normalized) do
      [_, username, domain] ->
        {:ok, %{username: username, domain: domain, handle: "#{username}@#{domain}"}}

      _ ->
        {:error, :invalid_remote_handle}
    end
  end

  defp normalize_remote_dm_handle(_handle), do: {:error, :invalid_remote_handle}

  defp canonical_actor_handle?(username, domain, handle)
       when is_binary(username) and is_binary(domain) and is_binary(handle) do
    String.downcase(handle) == String.downcase("#{username}@#{domain}")
  end

  defp canonical_actor_handle?(_username, _domain, _handle), do: false

  defp canonical_actor_inbox_url(actor_payload, uri)
       when is_map(actor_payload) and is_binary(uri) do
    normalize_optional_string(
      actor_payload["inbox_url"] ||
        actor_payload[:inbox_url] ||
        actor_payload["inbox"] ||
        actor_payload[:inbox]
    ) || derive_actor_inbox_from_uri(uri)
  end

  defp canonical_actor_inbox_url(_actor_payload, _uri), do: nil

  defp valid_absolute_http_uri?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_absolute_http_uri?(_value), do: false

  defp derive_actor_inbox_from_uri(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host, port: port, path: path}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and is_binary(path) and
             path != "" ->
        normalized_path = String.trim_trailing(path, "/")

        %URI{scheme: scheme, host: host, port: port, path: normalized_path <> "/inbox"}
        |> URI.to_string()

      _ ->
        nil
    end
  end

  defp derive_actor_inbox_from_uri(_uri), do: nil

  defp normalize_optional_string(value) when is_binary(value),
    do: Elektrine.Strings.present(value)

  defp normalize_optional_string(_value), do: nil

  defp call(context, key, args) do
    context
    |> Map.fetch!(key)
    |> Kernel.apply(args)
  end
end
