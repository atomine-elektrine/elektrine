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

  alias Elektrine.Accounts
  alias Elektrine.Accounts.Authentication
  alias Elektrine.Developer
  alias Elektrine.Developer.ApiToken
  alias ElektrineWeb.API.Response
  alias ElektrineWeb.ClientIP
  alias ElektrineWeb.Plugs.APIAuth

  def init(opts) do
    %{
      scopes: Keyword.get(opts, :scopes, []),
      any: Keyword.get(opts, :any, true),
      optional: Keyword.get(opts, :optional, false),
      allow_api_token: Keyword.get(opts, :allow_api_token, false)
    }
  end

  def call(conn, opts) do
    case conn.assigns[:api_token] do
      %ApiToken{} = api_token ->
        case authorize_existing_token(api_token, opts) do
          :ok ->
            conn

          {:error, reason} ->
            if opts.optional do
              conn
            else
              auth_error(conn, reason)
            end
        end

      _ ->
        token = extract_token(conn)

        cond do
          # No token provided
          is_nil(token) and opts.optional ->
            conn

          is_nil(token) ->
            auth_error(conn, :missing_token)

          # Token doesn't have correct prefix
          not String.starts_with?(token, "ekt_") ->
            handle_non_pat_token(conn, token, opts)

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
                  auth_error(conn, reason)
                end
            end
        end
    end
  end

  defp authorize_existing_token(_api_token, %{scopes: []}), do: :ok

  defp authorize_existing_token(api_token, %{scopes: scopes, any: any?}) do
    case check_scopes(api_token, scopes, any?) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
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

  defp handle_non_pat_token(conn, token, opts) do
    cond do
      opts.allow_api_token ->
        case verify_api_token(token) do
          {:ok, user} ->
            conn
            |> assign(:current_user, user)
            |> assign(:auth_method, :api_token)

          {:error, reason} ->
            if opts.optional do
              conn
            else
              auth_error(conn, reason)
            end
        end

      opts.optional ->
        conn

      true ->
        auth_error(conn, :invalid_token_format)
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

  defp verify_api_token(token) do
    with {:ok, user_id} <- APIAuth.verify_token_internal(token) do
      try do
        user = Accounts.get_user!(user_id)

        case Authentication.ensure_user_active(user) do
          :ok -> {:ok, user}
          {:error, reason} -> {:error, reason}
        end
      rescue
        Ecto.NoResultsError -> {:error, :invalid_token}
      end
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

  defp auth_error(conn, :insufficient_scope) do
    conn
    |> Response.error(
      :forbidden,
      "insufficient_scope",
      "Token does not have required permissions"
    )
    |> halt()
  end

  defp auth_error(conn, :missing_token) do
    conn
    |> Response.error(:unauthorized, "missing_token", "API token required")
    |> halt()
  end

  defp auth_error(conn, :invalid_token_format) do
    conn
    |> Response.error(:unauthorized, "invalid_token_format", "Invalid token format")
    |> halt()
  end

  defp auth_error(conn, reason) do
    message =
      case reason do
        :invalid_token -> "Invalid or unknown token"
        :token_expired -> "Token has expired"
        :token_revoked -> "Token has been revoked"
        :account_banned -> "Account is not allowed to authenticate"
        :account_suspended -> "Account is not allowed to authenticate"
        _ -> "Authentication failed"
      end

    conn
    |> Response.error(:unauthorized, normalize_error_code(reason), message)
    |> halt()
  end

  defp normalize_error_code(code) when is_atom(code), do: Atom.to_string(code)
  defp normalize_error_code(_), do: "authentication_failed"

  defp get_client_ip(conn) do
    ClientIP.client_ip(conn)
  end
end
