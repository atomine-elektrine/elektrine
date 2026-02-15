defmodule ElektrineWeb.MastodonAPI.AppController do
  @moduledoc """
  Controller for Mastodon API app registration.

  Handles OAuth application registration, which is the first step
  in the OAuth flow for third-party clients.

  ## Endpoints

  * `POST /api/v1/apps` - Register a new application
  * `GET /api/v1/apps/verify_credentials` - Verify app credentials
  """

  use ElektrineWeb, :controller

  alias Elektrine.OAuth
  alias Elektrine.OAuth.Scopes

  action_fallback(ElektrineWeb.MastodonAPI.FallbackController)

  @doc """
  POST /api/v1/apps

  Registers a new OAuth application. This endpoint does not require authentication.

  ## Parameters

  * `client_name` (required) - Name of the application
  * `redirect_uris` (required) - Space-separated list of redirect URIs
  * `scopes` (optional) - Space-separated list of scopes (defaults to "read")
  * `website` (optional) - URL to the application's homepage

  ## Response

  Returns the app credentials including client_id and client_secret.
  """
  def create(conn, params) do
    scopes = Scopes.fetch_scopes(params, ["read"])
    user_id = get_user_id(conn)

    app_attrs =
      params
      |> Map.take(["client_name", "redirect_uris", "website"])
      |> string_keys_to_atoms()
      |> Map.put(:scopes, scopes)
      |> maybe_put_user_id(user_id)

    with {:ok, app} <- OAuth.create_app(app_attrs) do
      conn
      |> put_status(:ok)
      |> json(render_app(app))
    end
  end

  @doc """
  GET /api/v1/apps/verify_credentials

  Confirms that the app's OAuth token is valid.

  ## Response

  Returns a compact representation of the app (without client_secret).
  """
  def verify_credentials(conn, _params) do
    case conn.assigns[:token] do
      nil ->
        {:error, :unauthorized}

      token ->
        app = token.app

        conn
        |> put_status(:ok)
        |> json(render_app_compact(app))
    end
  end

  # Private functions

  defp get_user_id(%{assigns: %{user: %{id: user_id}}}), do: user_id
  defp get_user_id(_conn), do: nil

  defp string_keys_to_atoms(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  rescue
    ArgumentError -> map
  end

  defp maybe_put_user_id(attrs, nil), do: attrs
  defp maybe_put_user_id(attrs, user_id), do: Map.put(attrs, :user_id, user_id)

  defp render_app(app) do
    %{
      id: to_string(app.id),
      name: app.client_name,
      website: app.website,
      redirect_uri: app.redirect_uris,
      client_id: app.client_id,
      client_secret: app.client_secret,
      vapid_key: get_vapid_key()
    }
  end

  defp render_app_compact(app) do
    %{
      id: to_string(app.id),
      name: app.client_name,
      website: app.website,
      vapid_key: get_vapid_key()
    }
  end

  defp get_vapid_key do
    # VAPID key for web push notifications
    # This would be configured in your application config
    Application.get_env(:elektrine, :vapid_public_key, "")
  end
end
