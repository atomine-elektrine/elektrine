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
      {:ok, claims} ->
        case fetch_active_user(claims.user_id) do
          {:ok, user} ->
            if password_changed_at_unix(user) == claims.password_changed_at and
                 auth_valid_after_unix(user) == claims.auth_valid_after do
              socket = assign(socket, :user_id, user.id)
              {:ok, socket}
            else
              :error
            end

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
           max_age: 300
         ) do
      {:ok,
       %{
         "user_id" => user_id,
         "password_changed_at" => password_changed_at,
         "auth_valid_after" => auth_valid_after
       }}
      when is_integer(user_id) and is_integer(password_changed_at) and
             is_integer(auth_valid_after) ->
        {:ok,
         %{
           user_id: user_id,
           password_changed_at: password_changed_at,
           auth_valid_after: auth_valid_after
         }}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_token}
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

  defp password_changed_at_unix(user) do
    case user.last_password_change do
      %DateTime{} = changed_at -> DateTime.to_unix(changed_at, :second)
      _ -> 0
    end
  end

  defp auth_valid_after_unix(user) do
    case user.auth_valid_after do
      %DateTime{} = valid_after -> DateTime.to_unix(valid_after, :second)
      _ -> 0
    end
  end
end
