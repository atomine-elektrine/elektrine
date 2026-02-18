defmodule ElektrineChatWeb.API.ServerController do
  @moduledoc """
  API controller for Discord-like servers and server channels.
  """
  use ElektrineChatWeb, :controller

  alias ElektrineChat, as: Messaging

  action_fallback ElektrineChatWeb.FallbackController

  @doc """
  GET /api/servers
  Lists all servers for the current user.
  """
  def index(conn, params) do
    user = conn.assigns[:current_user]
    limit = parse_int(params["limit"], 50)

    servers = Messaging.list_servers(user.id, limit: limit)

    conn
    |> put_status(:ok)
    |> json(%{servers: Enum.map(servers, &format_server_summary(&1, user.id))})
  end

  @doc """
  GET /api/servers/:id
  Shows a server with its channels.
  """
  def show(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    case Messaging.get_server(String.to_integer(id), user.id) do
      {:ok, server} ->
        conn
        |> put_status(:ok)
        |> json(%{
          server: format_server_summary(server, user.id),
          channels: Enum.map(server.channels, &format_channel/1)
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Server not found"})
    end
  end

  @doc """
  POST /api/servers
  Creates a new server and a default #general channel.
  """
  def create(conn, params) do
    user = conn.assigns[:current_user]

    attrs = %{
      name: params["name"],
      description: params["description"],
      icon_url: params["icon_url"],
      is_public: parse_bool(params["is_public"], false)
    }

    case Messaging.create_server(user.id, attrs) do
      {:ok, server} ->
        conn
        |> put_status(:created)
        |> json(%{
          message: "Server created",
          server: format_server_summary(server, user.id),
          channels: Enum.map(server.channels, &format_channel/1)
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Validation failed", errors: format_errors(changeset)})

      {:error, :already_member} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to initialize server membership"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to create server: #{inspect(reason)}"})
    end
  end

  @doc """
  POST /api/servers/:server_id/join
  Joins a public server.
  """
  def join(conn, %{"server_id" => server_id}) do
    user = conn.assigns[:current_user]

    case Messaging.join_server(String.to_integer(server_id), user.id) do
      {:ok, _member} ->
        case Messaging.get_server(String.to_integer(server_id), user.id) do
          {:ok, server} ->
            conn
            |> put_status(:ok)
            |> json(%{
              message: "Joined server",
              server: format_server_summary(server, user.id),
              channels: Enum.map(server.channels, &format_channel/1)
            })

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{error: "Server not found"})
        end

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Server not found"})

      {:error, :not_public} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "This server is private"})

      {:error, :already_member} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Already a member of this server"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to join server: #{inspect(reason)}"})
    end
  end

  @doc """
  POST /api/servers/:server_id/channels
  Creates a new channel in the server.
  """
  def create_channel(conn, %{"server_id" => server_id} = params) do
    user = conn.assigns[:current_user]

    attrs = %{
      name: params["name"],
      description: params["description"],
      channel_topic: params["channel_topic"],
      channel_position: parse_int(params["channel_position"], nil)
    }

    case Messaging.create_server_channel(String.to_integer(server_id), user.id, attrs) do
      {:ok, channel} ->
        conn
        |> put_status(:created)
        |> json(%{
          message: "Channel created",
          channel: format_channel(channel)
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Server not found"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "You don't have permission to create channels in this server"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Validation failed", errors: format_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Failed to create channel: #{inspect(reason)}"})
    end
  end

  defp format_server_summary(server, current_user_id) do
    role =
      case Messaging.get_server_member(server.id, current_user_id) do
        nil -> nil
        member -> member.role
      end

    %{
      id: server.id,
      name: server.name,
      description: server.description,
      icon_url: server.icon_url,
      is_public: server.is_public,
      member_count: server.member_count,
      creator_id: server.creator_id,
      role: role,
      inserted_at: server.inserted_at,
      updated_at: server.updated_at
    }
  end

  defp format_channel(channel) do
    %{
      id: channel.id,
      name: channel.name,
      description: channel.description,
      type: channel.type,
      channel_topic: channel.channel_topic,
      channel_position: channel.channel_position,
      server_id: channel.server_id,
      inserted_at: channel.inserted_at,
      updated_at: channel.updated_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp parse_bool(nil, default), do: default
  defp parse_bool(value, _default) when is_boolean(value), do: value

  defp parse_bool(value, default) when is_binary(value) do
    case String.downcase(value) do
      "true" -> true
      "1" -> true
      "false" -> false
      "0" -> false
      _ -> default
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end
end
