defmodule ElektrineWeb.UserSocket do
  use Phoenix.Socket
  require Logger

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Authentication

  # Channels
  channel "call:*", ElektrineWeb.CallChannel
  channel "mobile:*", ElektrineWeb.MobileChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case verify_phoenix_token(token) do
      {:ok, user_id} ->
        case fetch_active_user(user_id) do
          {:ok, user} ->
            socket = assign(socket, :user_id, user.id)
            {:ok, socket}

          {:error, _reason} ->
            :error
        end

      {:error, _reason} ->
        :error
    end
  end

  # Support API token authentication for mobile apps
  @impl true
  def connect(%{"api_token" => token}, socket, _connect_info) do
    case ElektrineWeb.Plugs.APIAuth.verify_user_token(token) do
      {:ok, user} ->
        socket = assign(socket, :user_id, user.id)
        {:ok, socket}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info) do
    :error
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"

  # Verify the Phoenix session token
  defp verify_phoenix_token(token) do
    case Phoenix.Token.verify(
           ElektrineWeb.Endpoint,
           "user socket",
           token,
           # 24 hours
           max_age: 86_400
         ) do
      {:ok, user_id} -> {:ok, user_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_active_user(user_id) do
    user = Accounts.get_user!(user_id)

    case Authentication.ensure_user_active(user) do
      :ok -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.NoResultsError -> {:error, :invalid_token}
  end
end
