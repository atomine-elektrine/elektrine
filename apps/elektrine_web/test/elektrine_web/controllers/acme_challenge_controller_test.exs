defmodule ElektrineWeb.AcmeChallengeControllerTest do
  use ElektrineWeb.ConnCase, async: false

  alias Elektrine.CustomDomains.AcmeChallengeStore

  setup do
    # Ensure AcmeChallengeStore is started
    case GenServer.whereis(AcmeChallengeStore) do
      nil ->
        {:ok, _pid} = AcmeChallengeStore.start_link([])

      _pid ->
        :ok
    end

    :ok
  end

  describe "GET /.well-known/acme-challenge/:token" do
    test "returns challenge response for valid token", %{conn: conn} do
      token = "test-challenge-token-#{System.unique_integer()}"
      response = "test-response.key-authorization"

      # Store the challenge
      AcmeChallengeStore.put(token, response)

      conn = get(conn, ~p"/.well-known/acme-challenge/#{token}")

      assert text_response(conn, 200) == response
    end

    test "returns 404 for non-existent token", %{conn: conn} do
      conn = get(conn, ~p"/.well-known/acme-challenge/nonexistent-token")

      assert text_response(conn, 404) == "Challenge not found"
    end

    test "returns plain text content type", %{conn: conn} do
      token = "content-type-test-#{System.unique_integer()}"
      AcmeChallengeStore.put(token, "response")

      conn = get(conn, ~p"/.well-known/acme-challenge/#{token}")

      assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    end
  end
end
