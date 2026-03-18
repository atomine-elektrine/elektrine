defmodule ElektrineWeb.BlueskyIdentityController do
  use ElektrineWeb, :controller

  alias Elektrine.Profiles

  def well_known_did(conn, _params) do
    case Profiles.get_verified_custom_domain_for_host(conn.host) do
      %{user: user} ->
        case bluesky_did_for_user(user) do
          did when is_binary(did) ->
            conn
            |> put_resp_content_type("text/plain")
            |> send_resp(200, did)

          _ ->
            send_not_found(conn)
        end

      _ ->
        send_not_found(conn)
    end
  end

  defp bluesky_did_for_user(%{bluesky_did: did}) when is_binary(did) do
    case String.trim(did) do
      "did:" <> _ = trimmed -> trimmed
      _ -> nil
    end
  end

  defp bluesky_did_for_user(%{bluesky_identifier: "did:" <> _ = did}) when is_binary(did) do
    String.trim(did)
  end

  defp bluesky_did_for_user(_), do: nil

  defp send_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> text("Not found")
  end
end
