defmodule ElektrineWeb.Plugs.MastodonAPIAuth do
  @moduledoc """
  Authentication plug for the Mastodon-compatible API.

  Extracts and validates OAuth bearer tokens from the Authorization header.
  Sets `conn.assigns.token` and `conn.assigns.user` on successful authentication.

  ## Options

  * `:required` - If `true`, authentication is required (default: `false`)
  * `:scopes` - List of required scopes (default: `[]`)
  """

  import Plug.Conn

  alias Elektrine.OAuth
  alias Elektrine.OAuth.Token

  @behaviour Plug

  @impl true
  def init(opts) do
    %{
      required: Keyword.get(opts, :required, false),
      scopes: Keyword.get(opts, :scopes, [])
    }
  end

  @impl true
  def call(conn, opts) do
    with {:ok, token_string} <- get_token(conn),
         {:ok, token} <- OAuth.get_token(token_string),
         :ok <- validate_token(token),
         :ok <- validate_scopes(token, opts.scopes) do
      conn
      |> assign(:token, token)
      |> assign(:user, token.user)
    else
      {:error, :no_token} when opts.required == false ->
        conn
        |> assign(:token, nil)
        |> assign(:user, nil)

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.put_view(json: ElektrineWeb.MastodonAPI.ErrorView)
        |> Phoenix.Controller.render(:error, error: error_message(reason))
        |> halt()
    end
  end

  @doc """
  Extracts the bearer token from the Authorization header.
  """
  @spec get_token(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :no_token}
  def get_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      ["bearer " <> token] -> {:ok, token}
      _ -> {:error, :no_token}
    end
  end

  defp validate_token(%Token{} = token) do
    if OAuth.token_valid?(token) do
      :ok
    else
      {:error, :token_expired}
    end
  end

  defp validate_token(_), do: {:error, :invalid_token}

  defp validate_scopes(_token, []), do: :ok

  defp validate_scopes(%Token{} = token, required_scopes) do
    OAuth.validate_scopes(token, required_scopes)
  end

  defp error_message(:no_token), do: "The access token is invalid"
  defp error_message(:not_found), do: "The access token is invalid"
  defp error_message(:invalid_token), do: "The access token is invalid"
  defp error_message(:token_expired), do: "The access token has expired"
  defp error_message(:insufficient_scope), do: "This action is outside the authorized scopes"
  defp error_message(_), do: "Authentication required"
end
