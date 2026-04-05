defmodule ElektrineWeb.OIDCClientController do
  use ElektrineWeb, :controller

  alias Elektrine.OAuth

  @recommended_scopes ["openid", "profile", "email", "read"]

  @scope_options [
    %{value: "openid", description: "Required if the app needs an ID token for sign-in."},
    %{value: "profile", description: "Lets the app read basic profile details."},
    %{value: "email", description: "Lets the app read the account email address."},
    %{value: "read", description: "Lets the app read account data without write access."}
  ]

  def index(conn, _params) do
    render(conn, :index,
      apps: OAuth.get_user_apps(conn.assigns.current_user),
      current_user: conn.assigns.current_user
    )
  end

  def new(conn, _params) do
    render(conn, :new,
      changeset: OAuth.App.register_changeset(%OAuth.App{}, %{}),
      scope_options: @scope_options,
      selected_scopes: @recommended_scopes,
      current_user: conn.assigns.current_user
    )
  end

  def edit(conn, %{"id" => id}) do
    case OAuth.get_user_app(conn.assigns.current_user, id) do
      nil ->
        conn
        |> put_flash(:error, "OAuth client not found.")
        |> redirect(to: ~p"/account/developer/oidc/clients")

      app ->
        render(conn, :edit,
          app: app,
          changeset: OAuth.App.changeset(app, %{}),
          scope_options: @scope_options,
          selected_scopes: app.scopes,
          redirect_uri_text: Enum.join(OAuth.App.redirect_uri_list(app), "\n"),
          current_user: conn.assigns.current_user
        )
    end
  end

  def create(conn, %{"app" => app_params}) do
    scopes = normalize_scopes(app_params["scopes"])

    attrs =
      app_params
      |> Map.put("scopes", scopes)
      |> Map.put("redirect_uris", normalize_redirect_uris(app_params["redirect_uris"]))
      |> Map.put("user_id", conn.assigns.current_user.id)

    case OAuth.create_app(attrs) do
      {:ok, _app} ->
        conn
        |> put_flash(:info, "OAuth client created.")
        |> redirect(to: ~p"/account/developer/oidc/clients")

      {:error, changeset} ->
        render(conn, :new,
          changeset: changeset,
          scope_options: @scope_options,
          selected_scopes: scopes,
          current_user: conn.assigns.current_user
        )
    end
  end

  def delete(conn, %{"id" => id}) do
    case OAuth.get_user_app(conn.assigns.current_user, id) do
      nil ->
        conn
        |> put_flash(:error, "OAuth client not found.")
        |> redirect(to: ~p"/account/developer/oidc/clients")

      app ->
        {:ok, _} = OAuth.delete_app(app.id)

        conn
        |> put_flash(:info, "OAuth client deleted.")
        |> redirect(to: ~p"/account/developer/oidc/clients")
    end
  end

  def update(conn, %{"id" => id, "app" => app_params}) do
    scopes = normalize_scopes(app_params["scopes"])

    attrs =
      app_params
      |> Map.put("scopes", scopes)
      |> Map.put("redirect_uris", normalize_redirect_uris(app_params["redirect_uris"]))

    case OAuth.update_user_app(conn.assigns.current_user, id, attrs) do
      {:ok, _app} ->
        conn
        |> put_flash(:info, "OAuth client updated.")
        |> redirect(to: ~p"/account/developer/oidc/clients")

      {:error, changeset} ->
        app = OAuth.get_user_app(conn.assigns.current_user, id)

        render(conn, :edit,
          app: app,
          changeset: changeset,
          scope_options: @scope_options,
          selected_scopes: scopes,
          redirect_uri_text: app_params["redirect_uris"] || "",
          current_user: conn.assigns.current_user
        )

      nil ->
        conn
        |> put_flash(:error, "OAuth client not found.")
        |> redirect(to: ~p"/account/developer/oidc/clients")
    end
  end

  def rotate_secret(conn, %{"id" => id}) do
    case OAuth.rotate_app_secret(conn.assigns.current_user, id) do
      {:ok, _app} ->
        conn
        |> put_flash(:info, "Client secret rotated.")
        |> redirect(to: ~p"/account/developer/oidc/clients")

      nil ->
        conn
        |> put_flash(:error, "OAuth client not found.")
        |> redirect(to: ~p"/account/developer/oidc/clients")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not rotate client secret.")
        |> redirect(to: ~p"/account/developer/oidc/clients")
    end
  end

  defp normalize_scopes(nil), do: ["openid", "profile", "email", "read"]
  defp normalize_scopes(scopes) when is_list(scopes), do: Enum.reject(scopes, &(&1 in [nil, ""]))
  defp normalize_scopes(_), do: ["openid", "profile", "email", "read"]

  defp normalize_redirect_uris(value) when is_binary(value) do
    value
    |> String.split(~r/[\r\n\s]+/, trim: true)
    |> Enum.join(" ")
  end

  defp normalize_redirect_uris(_), do: ""
end
