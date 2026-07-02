defmodule ElektrineWeb.API.AppController do
  @moduledoc """
  OAuth application registration for API-compatible clients.
  """

  use ElektrineWeb, :controller

  alias Elektrine.OAuth
  alias Elektrine.OAuth.App

  def index(%{assigns: %{current_user: current_user}} = conn, _params) do
    apps =
      current_user
      |> OAuth.get_user_apps()
      |> Enum.map(&format_listed_app/1)

    json(conn, apps)
  end

  def create(conn, params) do
    attrs = %{
      client_name: params["client_name"],
      website: params["website"],
      redirect_uris: normalize_redirect_uris(params["redirect_uris"]),
      scopes: normalize_scopes(params)
    }

    case OAuth.create_app(attrs) do
      {:ok, app} ->
        conn
        |> put_status(:created)
        |> json(format_app(app))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "invalid_client_metadata", details: translate_errors(changeset)})
    end
  end

  def verify_credentials(conn, params) do
    case verify_app(conn, params) do
      {:ok, app} ->
        json(conn, format_verified_app(app))

      :error ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_client"})
    end
  end

  defp format_app(%App{} = app) do
    redirect_uris = App.redirect_uri_list(app)

    %{
      id: to_string(app.id),
      name: app.client_name,
      website: app.website,
      redirect_uri: Enum.join(redirect_uris, "\n"),
      client_id: app.client_id,
      client_secret: App.client_secret_value(app),
      vapid_key: nil
    }
  end

  defp format_listed_app(%App{} = app) do
    redirect_uris = App.redirect_uri_list(app)

    %{
      id: to_string(app.id),
      name: app.client_name,
      website: app.website,
      redirect_uri: Enum.join(redirect_uris, "\n"),
      client_id: app.client_id,
      client_secret: nil,
      client_secret_fingerprint: App.client_secret_fingerprint(app),
      scopes: app.scopes || [],
      vapid_key: nil
    }
  end

  defp format_verified_app(%App{} = app) do
    %{
      name: app.client_name,
      website: app.website,
      vapid_key: nil
    }
  end

  defp verify_app(conn, params) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, oauth_token} <- OAuth.get_token(token),
         %App{} = app <- oauth_token.app do
      {:ok, app}
    else
      _ -> verify_app_by_credentials(conn, params)
    end
  end

  defp verify_app_by_credentials(conn, params) do
    {client_id, client_secret} = client_credentials(conn, params)

    case {client_id, client_secret} do
      {id, secret} when is_binary(id) and is_binary(secret) ->
        case OAuth.get_app_by_credentials(id, secret) do
          %App{} = app -> {:ok, app}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, String.trim(token)}
      _ -> :error
    end
  end

  defp client_credentials(conn, params) do
    case basic_credentials(conn) do
      {client_id, client_secret} -> {client_id, client_secret}
      nil -> {params["client_id"], params["client_secret"]}
    end
  end

  defp basic_credentials(conn) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [client_id, client_secret] <- String.split(decoded, ":", parts: 2) do
      {URI.decode_www_form(client_id), URI.decode_www_form(client_secret)}
    else
      _ -> nil
    end
  end

  defp normalize_redirect_uris(value) when is_list(value), do: Enum.join(value, " ")
  defp normalize_redirect_uris(value) when is_binary(value), do: value
  defp normalize_redirect_uris(_value), do: ""

  defp normalize_scopes(params) do
    params
    |> OAuth.Scopes.fetch_scopes(["read"])
    |> Enum.reject(&String.starts_with?(&1, "admin:"))
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
