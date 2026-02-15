defmodule ElektrineWeb.Plugs.EnsureHTTPSignaturePlug do
  @moduledoc """
  Ensures HTTP signature has been validated by HTTPSignaturePlug.

  This plug rejects requests without valid signatures when in authorized fetch mode.
  It also handles special cases like Delete activities from unknown/deleted actors.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  def init(opts), do: opts

  # Valid signature - allow through
  def call(%{assigns: %{valid_signature: true}} = conn, _opts), do: conn

  def call(conn, _opts) do
    # Check if this is an ActivityPub request
    content_type = get_req_header(conn, "content-type") |> List.first() || ""
    accept = get_req_header(conn, "accept") |> List.first() || ""

    is_activitypub =
      String.contains?(content_type, "activity+json") or
        String.contains?(content_type, "ld+json") or
        String.contains?(accept, "activity+json") or
        String.contains?(accept, "ld+json")

    if is_activitypub do
      handle_unsigned_request(conn)
    else
      conn
    end
  end

  defp handle_unsigned_request(conn) do
    # Special handling for Delete activities from unknown actors
    # Mastodon keeps retrying Delete activities, so accept them to stop the retries
    if conn.method == "POST" and delete_activity?(conn) do
      Logger.debug("Accepting Delete activity from unknown/unsigned actor")

      conn
      |> put_status(:accepted)
      |> json(%{})
      |> halt()
    else
      # Check if authorized fetch mode is enabled
      if authorized_fetch_enabled?() do
        Logger.warning("Rejecting unsigned ActivityPub request to #{conn.request_path}")

        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Request not signed"})
        |> halt()
      else
        # Allow unsigned requests in non-authorized fetch mode
        conn
      end
    end
  end

  defp delete_activity?(conn) do
    case conn.body_params do
      %{"type" => "Delete"} -> true
      _ -> false
    end
  end

  defp authorized_fetch_enabled? do
    Application.get_env(:elektrine, :activitypub, [])
    |> Keyword.get(:authorized_fetch_mode, false)
  end
end
