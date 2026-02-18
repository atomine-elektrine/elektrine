defmodule ElektrineChatWeb.UserSocket do
  use Phoenix.Socket

  channel "mobile:*", ElektrineChatWeb.MobileChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case verify_phoenix_token(token) do
      {:ok, user_id} -> {:ok, assign(socket, :user_id, user_id)}
      {:error, _reason} -> :error
    end
  end

  @impl true
  def connect(%{"api_token" => token}, socket, _connect_info) do
    case ElektrineChatWeb.Plugs.APIAuth.verify_token_internal(token) do
      {:ok, user_id} -> {:ok, assign(socket, :user_id, user_id)}
      {:error, _reason} -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"

  defp verify_phoenix_token(token) do
    case Phoenix.Token.verify(ElektrineChatWeb.Endpoint, "user socket", token, max_age: 86_400) do
      {:ok, user_id} -> {:ok, user_id}
      {:error, reason} -> {:error, reason}
    end
  end
end
