defmodule ElektrineWeb.API.AtomineAttestationControllerTest do
  use ElektrineWeb.ConnCase, async: true

  describe "GET /api/atomine/issuer" do
    test "returns public issuer metadata", %{conn: conn} do
      conn = get(conn, "/api/atomine/issuer")
      response = json_response(conn, 200)

      assert response["protocol"] == "atomine-attestations"
      assert response["version"] == "v1"
      assert "anonymous_effort_token" in response["artifacts"]
      assert response["endpoints"]["verify_artifact"] =~ "/api/atomine/artifacts/verify"

      assert response["endpoints"]["spend_anonymous_token"] =~
               "/api/atomine/anonymous-tokens/spend"
    end
  end

  describe "anonymous effort token flow" do
    test "issues, verifies, and spends a token for an external audience", %{conn: conn} do
      challenge_conn = post(conn, "/api/atomine/pow/challenge", %{difficulty: 0})
      challenge = json_response(challenge_conn, 200)

      token_conn =
        post(conn, "/api/atomine/anonymous-tokens", %{
          challenge: challenge["challenge"],
          solution: "any-solution"
        })

      token_response = json_response(token_conn, 200)
      token = token_response["token"]
      assert token_response["kind"] == "anonymous_effort_token"

      verify_conn = post(conn, "/api/atomine/artifacts/verify", %{artifact: token})

      assert %{"valid" => true, "persisted" => true, "status" => "issued"} =
               json_response(verify_conn, 200)

      spend_conn =
        post(conn, "/api/atomine/anonymous-tokens/spend", %{
          token: token,
          audience: "https://shop.example/signup",
          nonce: "signup-1"
        })

      spend_response = json_response(spend_conn, 200)
      assert spend_response["status"] == "redeemed"
      assert spend_response["spend"]["audience"] == "https://shop.example/signup"
      assert spend_response["spend"]["nonce"] == "signup-1"

      replay_conn =
        post(conn, "/api/atomine/anonymous-tokens/spend", %{
          token: token,
          audience: "https://shop.example/signup"
        })

      assert json_response(replay_conn, 422)["error"] == "already redeemed"
    end

    test "requires audience when spending a token", %{conn: conn} do
      conn = post(conn, "/api/atomine/anonymous-tokens/spend", %{token: "token"})
      assert json_response(conn, 422)["error"] == "missing audience"
    end
  end
end
