defmodule ElektrineWeb.OIDCGrantController do
  use ElektrineWeb, :controller

  alias Elektrine.OAuth

  def index(conn, _params) do
    grants =
      conn.assigns.current_user
      |> OAuth.get_user_tokens()
      |> Enum.group_by(& &1.app_id)
      |> Enum.map(fn {_app_id, tokens} ->
        latest = Enum.max_by(tokens, & &1.inserted_at, DateTime)

        %{
          app: latest.app,
          scopes: tokens |> Enum.flat_map(& &1.scopes) |> Enum.uniq() |> Enum.sort(),
          active_token_count: length(tokens),
          last_granted_at: latest.inserted_at
        }
      end)
      |> Enum.sort_by(&DateTime.to_unix(&1.last_granted_at), :desc)

    render(conn, :index, grants: grants)
  end

  def delete(conn, %{"id" => id}) do
    :ok = OAuth.revoke_user_app_grants(conn.assigns.current_user, id)

    conn
    |> put_flash(:info, "App access revoked.")
    |> redirect(to: ~p"/account/developer/oidc/grants")
  end
end
