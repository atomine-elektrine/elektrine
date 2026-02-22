defmodule ElektrineWeb.UserSocket do
  use Phoenix.Socket
  require Logger

  # Channels
  channel "call:*", ElektrineWeb.CallChannel
  channel "mobile:*", ElektrineWeb.MobileChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    # Verify user token (Phoenix session token) and assign user_id to socket
    case verify_phoenix_token(token) do
      {:ok, user_id} ->
        socket = assign(socket, :user_id, user_id)
        {:ok, socket}

      {:error, _reason} ->
        :error
    end
  end

  # Support API token authentication for mobile apps
  @impl true
  def connect(%{"api_token" => token}, socket, _connect_info) do
    case ElektrineWeb.Plugs.APIAuth.verify_token_internal(token) do
      {:ok, user_id} ->
        socket = assign(socket, :user_id, user_id)
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
end
