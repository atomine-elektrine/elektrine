defmodule Elektrine.Messaging.Servers do
  @moduledoc """
  Context for community servers and server-scoped channels.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Elektrine.Repo

  alias Elektrine.Messaging.{
    Conversation,
    Conversations,
    Federation,
    Server,
    ServerMember
  }

  @default_discovery_timeout_ms 5_000

  @doc """
  Lists all servers where the user has an active membership.
  """
  def list_servers(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(s in Server,
      join: sm in ServerMember,
      on: sm.server_id == s.id and sm.user_id == ^user_id and is_nil(sm.left_at),
      order_by: [desc: sm.inserted_at],
      limit: ^limit,
      preload: [:creator]
    )
    |> Repo.all()
  end

  @doc """
  Lists public servers the user can discover and join.
  """
  def list_public_servers(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    query = normalize_search_query(Keyword.get(opts, :query))
    _ = maybe_sync_remote_public_servers(query, limit, opts)

    joined_server_ids_query =
      from(sm in ServerMember,
        where: sm.user_id == ^user_id and is_nil(sm.left_at),
        select: sm.server_id
      )

    from(s in Server,
      where: s.is_public == true and s.id not in subquery(joined_server_ids_query),
      order_by: [desc: s.member_count, desc: s.last_activity_at, desc: s.inserted_at],
      limit: ^limit,
      preload: [:creator]
    )
    |> maybe_filter_discoverable_servers(query)
    |> Repo.all()
  end

  @doc """
  Lists local public servers for federation directory export.
  """
  def list_public_directory_servers(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    query = normalize_search_query(Keyword.get(opts, :query))

    from(s in Server,
      where: s.is_public == true and s.is_federated_mirror != true,
      order_by: [desc: s.member_count, desc: s.last_activity_at, desc: s.inserted_at],
      limit: ^limit,
      preload: [:creator]
    )
    |> maybe_filter_discoverable_servers(query)
    |> Repo.all()
  end

  @doc """
  Gets a server with channels for a user.
  """
  def get_server(server_id, user_id) do
    channel_query =
      from(c in Conversation,
        where: c.type == "channel",
        order_by: [asc: c.channel_position, asc: c.inserted_at]
      )

    from(s in Server,
      join: sm in ServerMember,
      on: sm.server_id == s.id and sm.user_id == ^user_id and is_nil(sm.left_at),
      where: s.id == ^server_id,
      preload: [:creator, channels: ^channel_query]
    )
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      server -> {:ok, server}
    end
  end

  @doc """
  Gets the active membership record for a user in a server.
  """
  def get_server_member(server_id, user_id) do
    from(sm in ServerMember,
      where: sm.server_id == ^server_id and sm.user_id == ^user_id and is_nil(sm.left_at)
    )
    |> Repo.one()
  end

  @doc """
  Creates a server and seeds it with a default `#general` channel.
  """
  def create_server(creator_id, attrs) do
    attrs = Map.put(attrs, :creator_id, creator_id)

    Repo.transaction(fn ->
      with {:ok, server} <- %Server{} |> Server.changeset(attrs) |> Repo.insert(),
           {:ok, _owner_member} <- do_add_member(server.id, creator_id, "owner"),
           {:ok, _general_channel} <- do_create_channel(server.id, creator_id, %{}) do
        get_server(server.id, creator_id)
      else
        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:ok, server}} ->
        Federation.maybe_push_for_server(server.id)
        {:ok, server}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a text channel inside a server.
  Only owners/admins/moderators can create channels.
  """
  def create_server_channel(server_id, creator_id, attrs) do
    with %Server{} <- Repo.get(Server, server_id),
         %ServerMember{} = member <- get_server_member(server_id, creator_id),
         true <- member.role in ["owner", "admin", "moderator"] do
      Repo.transaction(fn ->
        do_create_channel(server_id, creator_id, attrs)
      end)
      |> case do
        {:ok, {:ok, channel}} ->
          Federation.maybe_push_for_server(server_id)
          {:ok, channel}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    else
      nil -> {:error, :not_found}
      false -> {:error, :unauthorized}
    end
  end

  @doc """
  Joins a public server and auto-joins all current server channels.
  """
  def join_server(server_id, user_id) do
    case Repo.get(Server, server_id) do
      nil ->
        {:error, :not_found}

      %Server{is_public: false} ->
        {:error, :not_public}

      %Server{} = server ->
        with :ok <- maybe_hydrate_mirror_server(server) do
          Repo.transaction(fn ->
            with {:ok, member} <- do_add_member(server_id, user_id, "member"),
                 :ok <- maybe_add_user_to_server_channels(server, user_id) do
              {:ok, member}
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
          |> case do
            {:ok, {:ok, member}} ->
              Federation.maybe_push_for_server(server_id)
              {:ok, member}

            {:ok, other} ->
              other

            {:error, reason} ->
              {:error, reason}
          end
        end
    end
  end

  defp do_create_channel(server_id, creator_id, attrs) do
    next_position = next_channel_position(server_id)

    channel_attrs =
      attrs
      |> Map.take([
        :name,
        :description,
        :avatar_url,
        :channel_topic,
        :channel_position,
        :is_public
      ])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.put(:creator_id, creator_id)
      |> Map.put(:server_id, server_id)
      # Community-server default: channels are visible to all members unless marked private.
      |> Map.put_new(:is_public, true)
      |> Map.put_new(:name, "general")
      |> Map.put_new(:description, "Default server channel")
      |> Map.put_new(:channel_position, next_position)

    with {:ok, channel} <-
           %Conversation{}
           |> Conversation.channel_changeset(channel_attrs)
           |> Repo.insert(),
         :ok <- add_all_server_members_to_channel(server_id, channel.id) do
      {:ok, channel}
    end
  end

  defp next_channel_position(server_id) do
    from(c in Conversation,
      where: c.server_id == ^server_id and c.type == "channel",
      select: max(c.channel_position)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      position -> position + 1
    end
  end

  defp add_all_server_members_to_channel(server_id, channel_id) do
    user_ids =
      from(sm in ServerMember,
        where: sm.server_id == ^server_id and is_nil(sm.left_at),
        select: sm.user_id
      )
      |> Repo.all()

    Enum.reduce_while(user_ids, :ok, fn user_id, :ok ->
      case Conversations.add_member_to_conversation(channel_id, user_id, "member") do
        {:ok, _member} -> {:cont, :ok}
        {:error, :banned} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp add_user_to_all_server_channels(server_id, user_id) do
    channel_ids =
      from(c in Conversation,
        where: c.server_id == ^server_id and c.type == "channel",
        select: c.id
      )
      |> Repo.all()

    Enum.reduce_while(channel_ids, :ok, fn channel_id, :ok ->
      case Conversations.add_member_to_conversation(channel_id, user_id, "member") do
        {:ok, _member} -> {:cont, :ok}
        {:error, :banned} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Remote mirrored servers no longer auto-join all rooms. Room access is now
  # explicitly granted per channel by the authoritative origin.
  defp maybe_add_user_to_server_channels(%Server{is_federated_mirror: true}, _user_id), do: :ok

  defp maybe_add_user_to_server_channels(%Server{id: server_id}, user_id)
       when is_integer(server_id) and is_integer(user_id) do
    add_user_to_all_server_channels(server_id, user_id)
  end

  defp maybe_add_user_to_server_channels(_server, _user_id), do: {:error, :invalid_event_payload}

  defp do_add_member(server_id, user_id, role) do
    existing_member =
      Repo.get_by(ServerMember, server_id: server_id, user_id: user_id)

    case existing_member do
      nil ->
        ServerMember.add_member_changeset(server_id, user_id, role)
        |> Repo.insert()
        |> case do
          {:ok, member} ->
            update_member_count(server_id)
            {:ok, member}

          {:error, reason} ->
            {:error, reason}
        end

      %ServerMember{left_at: nil} ->
        {:error, :already_member}

      member ->
        member
        |> ServerMember.changeset(%{
          left_at: nil,
          joined_at: DateTime.utc_now(),
          role: role
        })
        |> Repo.update()
        |> case do
          {:ok, updated_member} ->
            update_member_count(server_id)
            {:ok, updated_member}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp update_member_count(server_id) do
    count =
      from(sm in ServerMember,
        where: sm.server_id == ^server_id and is_nil(sm.left_at),
        select: count()
      )
      |> Repo.one()

    from(s in Server, where: s.id == ^server_id)
    |> Repo.update_all(set: [member_count: count])
  end

  defp maybe_filter_discoverable_servers(query, nil), do: query

  defp maybe_filter_discoverable_servers(query, search_term) do
    pattern = "%#{search_term}%"

    from(s in query,
      where:
        ilike(s.name, ^pattern) or ilike(s.description, ^pattern) or
          ilike(s.origin_domain, ^pattern)
    )
  end

  defp normalize_search_query(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_search_query(_), do: nil

  defp maybe_sync_remote_public_servers(query, limit, opts) do
    include_remote = Keyword.get(opts, :include_remote, true)

    if include_remote and Federation.enabled?() do
      remote_servers =
        case Keyword.get(opts, :remote_discovery_fn) do
          fun when is_function(fun, 2) ->
            fun.(query, limit)

          _ ->
            fetch_remote_public_servers(query, limit)
        end

      remote_servers
      |> normalize_remote_public_servers()
      |> Enum.each(fn attrs ->
        case upsert_discovered_remote_server(attrs) do
          {:ok, _server} ->
            :ok

          {:error, :federation_origin_conflict} ->
            Logger.warning(
              "Skipping remote discovery entry due to federation origin conflict: #{attrs.federation_id}"
            )

          {:error, reason} ->
            Logger.warning(
              "Failed to upsert remote discovery entry #{attrs.federation_id}: #{inspect(reason)}"
            )
        end
      end)
    end

    :ok
  rescue
    error ->
      Logger.warning("Remote public server sync failed: #{Exception.message(error)}")
      :ok
  end

  defp fetch_remote_public_servers(query, limit) do
    peers = Federation.outgoing_peers()
    timeout_ms = remote_discovery_timeout_ms()

    if peers == [] do
      []
    else
      peers
      |> Task.async_stream(
        fn peer -> fetch_remote_public_servers_from_peer(peer, query, limit, timeout_ms) end,
        max_concurrency: min(length(peers), 4),
        timeout: timeout_ms + 1_000,
        ordered: false
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, servers}} ->
          servers

        {:ok, {:error, peer_domain, reason}} ->
          Logger.warning(
            "Remote server directory fetch failed for #{peer_domain}: #{inspect(reason)}"
          )

          []

        {:exit, reason} ->
          Logger.warning("Remote server directory fetch task exited: #{inspect(reason)}")
          []
      end)
    end
  end

  defp fetch_remote_public_servers_from_peer(peer, query, limit, timeout_ms) do
    path = "/_arblarg/servers/public"
    query_string = build_remote_discovery_query_string(query, limit)
    url = remote_public_servers_url(peer, path, query_string)
    headers = Federation.signed_headers(peer, "GET", path, query_string, "")
    request = Finch.build(:get, url, headers)

    case Finch.request(request, Elektrine.Finch, receive_timeout: timeout_ms, pool_timeout: 2_000) do
      {:ok, %Finch.Response{status: status, body: body}} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, payload} ->
            {:ok, parse_remote_discovery_payload(payload, peer)}

          _ ->
            {:error, peer.domain, :invalid_json}
        end

      {:ok, %Finch.Response{status: status, body: body}} ->
        {:error, peer.domain, {:http_error, status, truncate(body)}}

      {:error, reason} ->
        {:error, peer.domain, reason}
    end
  end

  defp parse_remote_discovery_payload(%{"servers" => servers}, peer) when is_list(servers) do
    Enum.map(servers, &normalize_remote_public_server(&1, peer))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_remote_discovery_payload(%{servers: servers}, peer) when is_list(servers) do
    Enum.map(servers, &normalize_remote_public_server(&1, peer))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_remote_discovery_payload(_payload, _peer), do: []

  defp normalize_remote_public_servers(servers) when is_list(servers) do
    Enum.map(servers, &normalize_remote_public_server(&1, nil))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_remote_public_servers(_), do: []

  defp normalize_remote_public_server(entry, peer) when is_map(entry) do
    peer_domain =
      case peer do
        %{domain: domain} when is_binary(domain) -> String.downcase(domain)
        _ -> normalize_optional_string(value_from(entry, :origin_domain))
      end

    origin_domain =
      normalize_optional_string(value_from(entry, :origin_domain))
      |> case do
        nil -> peer_domain
        value -> String.downcase(value)
      end

    remote_server_id = parse_int(value_from(entry, :server_id), nil)

    federation_id =
      normalize_optional_string(value_from(entry, :federation_id)) ||
        normalize_optional_string(value_from(entry, :id)) ||
        remote_server_federation_id(peer, remote_server_id)

    name = normalize_optional_string(value_from(entry, :name))
    is_public = parse_bool(value_from(entry, :is_public), true)

    cond do
      is_nil(name) ->
        nil

      is_nil(federation_id) ->
        nil

      is_nil(origin_domain) ->
        nil

      is_binary(peer_domain) and origin_domain != peer_domain ->
        nil

      is_public != true ->
        nil

      true ->
        %{
          name: name,
          description: normalize_optional_string(value_from(entry, :description)),
          icon_url: normalize_optional_string(value_from(entry, :icon_url)),
          is_public: true,
          member_count: max(parse_int(value_from(entry, :member_count), 0), 0),
          federation_id: federation_id,
          origin_domain: origin_domain
        }
    end
  end

  defp normalize_remote_public_server(_entry, _peer), do: nil

  defp upsert_discovered_remote_server(attrs) when is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      attrs
      |> Map.put(:is_federated_mirror, true)
      |> Map.put(:last_federated_at, now)

    case Repo.get_by(Server, federation_id: attrs.federation_id) do
      nil ->
        %Server{} |> Server.changeset(attrs) |> Repo.insert()

      %Server{origin_domain: existing_origin_domain} = server ->
        normalized_existing = normalize_optional_string(existing_origin_domain)

        if is_binary(normalized_existing) and
             String.downcase(normalized_existing) != String.downcase(attrs.origin_domain) do
          {:error, :federation_origin_conflict}
        else
          server |> Server.changeset(attrs) |> Repo.update()
        end
    end
  end

  defp maybe_hydrate_mirror_server(%Server{is_federated_mirror: true} = server) do
    if server_has_channels?(server.id) do
      :ok
    else
      case Federation.refresh_mirror_server_snapshot(server) do
        {:ok, _server} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Failed to hydrate mirror server #{server.id} (#{server.federation_id}): #{inspect(reason)}"
          )

          {:error, :federation_sync_unavailable}
      end
    end
  end

  defp maybe_hydrate_mirror_server(_server), do: :ok

  defp server_has_channels?(server_id) do
    from(c in Conversation,
      where: c.server_id == ^server_id and c.type == "channel",
      select: c.id,
      limit: 1
    )
    |> Repo.exists?()
  end

  defp remote_public_servers_url(peer, path, query_string) do
    query_suffix =
      case query_string do
        value when is_binary(value) ->
          if(Elektrine.Strings.present?(value), do: "?" <> value, else: "")

        _ ->
          ""
      end

    endpoint =
      case peer do
        %{directory_endpoint: endpoint} when is_binary(endpoint) ->
          if Elektrine.Strings.present?(endpoint),
            do: String.trim_trailing(endpoint, "/"),
            else: peer.base_url <> path

        _ ->
          peer.base_url <> path
      end

    endpoint <> query_suffix
  end

  defp build_remote_discovery_query_string(query, limit) do
    [
      {"limit", Integer.to_string(limit)},
      {"query", query}
    ]
    |> Enum.reject(fn {_key, value} ->
      is_nil(value) or (is_binary(value) and not Elektrine.Strings.present?(value))
    end)
    |> URI.encode_query()
  end

  defp remote_server_federation_id(%{base_url: base_url}, remote_server_id)
       when is_binary(base_url) and is_integer(remote_server_id) do
    "#{base_url}/_arblarg/servers/#{remote_server_id}"
  end

  defp remote_server_federation_id(_, _), do: nil

  defp remote_discovery_timeout_ms do
    Application.get_env(:elektrine, :messaging_federation, [])
    |> Keyword.get(:discovery_timeout_ms, @default_discovery_timeout_ms)
  end

  defp truncate(nil), do: ""

  defp truncate(body) when is_binary(body) do
    if byte_size(body) > 180 do
      binary_part(body, 0, 180) <> "..."
    else
      body
    end
  end

  defp truncate(body), do: inspect(body)

  defp value_from(data, key) when is_map(data) do
    Map.get(data, key) || Map.get(data, Atom.to_string(key))
  end

  defp value_from(_data, _key), do: nil

  defp normalize_optional_string(value) when is_binary(value),
    do: Elektrine.Strings.present(value)

  defp normalize_optional_string(_), do: nil

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp parse_bool(value, _default) when is_boolean(value), do: value

  defp parse_bool(value, default) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "1" -> true
      "false" -> false
      "0" -> false
      _ -> default
    end
  end

  defp parse_bool(nil, default), do: default
  defp parse_bool(_value, default), do: default
end
