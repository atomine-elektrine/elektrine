defmodule ElektrineWeb.AcmeChallengeController do
  @moduledoc """
  Controller for handling ACME HTTP-01 challenges.

  Let's Encrypt verifies domain ownership by requesting:

      GET /.well-known/acme-challenge/{token}

  This controller returns the pre-computed key authorization.
  Checks ETS store first (for main domains), then database (for custom domains).
  """

  use ElektrineWeb, :controller
  require Logger

  alias Elektrine.CustomDomains.AcmeChallengeStore

  @doc """
  Handles ACME HTTP-01 challenge requests.

  Returns the key authorization for the given token, or 404 if not found.
  """
  def challenge(conn, %{"token" => token}) do
    Logger.debug("ACME challenge request for token: #{token}")

    case AcmeChallengeStore.get(token) do
      nil ->
        Logger.warning("ACME challenge token not found: #{token}")

        conn
        |> put_status(:not_found)
        |> text("Challenge not found")

      response ->
        Logger.info("ACME challenge response for token #{token}")

        conn
        |> put_resp_content_type("text/plain")
        |> text(response)
    end
  end
end
