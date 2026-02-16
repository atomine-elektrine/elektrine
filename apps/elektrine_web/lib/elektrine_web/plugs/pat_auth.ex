defmodule ElektrineWeb.Plugs.PATAuth do
  @moduledoc """
  Plug for Personal Access Token (PAT) authentication.

  Authenticates API requests using tokens with the `ekt_` prefix.
  Supports scope-based authorization.

  ## Usage

  In your router:

      pipeline :api_with_pat do
        plug :accepts, ["json"]
        plug ElektrineWeb.Plugs.PATAuth
      end

  With required scopes:

      plug ElektrineWeb.Plugs.PATAuth, scopes: ["read:email"]

  With any of multiple scopes:

      plug ElektrineWeb.Plugs.PATAuth, scopes: ["read:email", "write:email"], any: true

  ## Authentication

  Clients should send the token in the Authorization header:

      Authorization: Bearer ekt_xxxxx

  Or via X-API-Key header:

      X-API-Key: ekt_xxxxx
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Elektrine.Developer
  alias Elektrine.Developer.ApiToken
  alias ElektrineWeb.ClientIP

  def init(opts) do
    %{
      scopes: Keyword.get(opts, :scopes, []),
      any: Keyword.get(opts, :any, true),
      optional: Keyword.get(opts, :optional, false)
    }
  end

  def call(conn, opts) do
    token = extract_token(conn)

    cond do
      # No token provided
      is_nil(token) and opts.optional ->
        conn

      is_nil(token) ->
        unauthorized(conn, "API token required")

      # Token doesn't have correct prefix
      not String.starts_with?(token, "ekt_") ->
        # Fall through to other auth methods if optional
        if opts.optional do
          conn
        else
          unauthorized(conn, "Invalid token format")
        end

      # Verify token
      true ->
        case verify_and_authorize(token, opts, conn) do
          {:ok, api_token} ->
            conn
            |> assign(:current_user, api_token.user)
            |> assign(:api_token, api_token)
            |> assign(:auth_method, :pat)

          {:error, reason} ->
            if opts.optional do
              conn
            else
              unauthorized(conn, error_message(reason))
            end
        end
    end
  end

  defp extract_token(conn) do
    # Try Authorization header first
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        String.trim(token)

      _ ->
        # Fall back to X-API-Key header
        case get_req_header(conn, "x-api-key") do
          [token] -> String.trim(token)
          _ -> nil
        end
    end
  end

  defp verify_and_authorize(token, opts, conn) do
    ip_address = get_client_ip(conn)

    case Developer.verify_api_token(token, ip_address) do
      {:ok, api_token} ->
        # Check scopes if required
        if Enum.empty?(opts.scopes) do
          {:ok, api_token}
        else
          check_scopes(api_token, opts.scopes, opts.any)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_scopes(api_token, required_scopes, any?) do
    has_required =
      if any? do
        ApiToken.has_any_scope?(api_token, required_scopes)
      else
        Enum.all?(required_scopes, &ApiToken.has_scope?(api_token, &1))
      end

    if has_required do
      {:ok, api_token}
    else
      {:error, :insufficient_scope}
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: ElektrineWeb.ErrorJSON)
    |> json(%{error: "unauthorized", message: message})
    |> halt()
  end

  defp error_message(:invalid_token), do: "Invalid or unknown token"
  defp error_message(:token_expired), do: "Token has expired"
  defp error_message(:token_revoked), do: "Token has been revoked"
  defp error_message(:insufficient_scope), do: "Token does not have required permissions"
  defp error_message(_), do: "Authentication failed"

  defp get_client_ip(conn) do
    ClientIP.client_ip(conn)
  end
end
