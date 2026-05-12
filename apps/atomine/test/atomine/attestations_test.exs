defmodule Atomine.AttestationsTest do
  use Elektrine.DataCase, async: true

  alias Atomine.Attestation
  alias Atomine.Attestations
  alias Elektrine.Repo

  describe "issuer_metadata/1" do
    test "describes public verifier endpoints" do
      metadata = Attestations.issuer_metadata("https://issuer.example")

      assert metadata.protocol == "atomine-attestations"
      assert metadata.version == "v1"
      assert "gate_proof" in metadata.artifacts
      assert "anonymous_effort_token" in metadata.artifacts

      assert metadata.endpoints.verify_artifact ==
               "https://issuer.example/api/atomine/artifacts/verify"

      assert metadata.endpoints.spend_anonymous_token ==
               "https://issuer.example/api/atomine/anonymous-tokens/spend"
    end
  end

  describe "anonymous effort tokens" do
    test "can be spent once against an audience" do
      {:ok, challenge} = Attestations.issue_pow_challenge(difficulty: 0)

      {:ok, token_attestation} =
        Attestations.issue_anonymous_effort_token(%{
          "challenge" => challenge["challenge"],
          "solution" => "any-solution",
          "gate_proof" => gate_proof(challenge["challenge"])
        })

      assert {:ok, redeemed} =
               Attestations.redeem_anonymous_effort_token(token_attestation.artifact, %{
                 "audience" => "https://shop.example/signup",
                 "nonce" => "checkout-123"
               })

      assert redeemed.status == "redeemed"
      assert redeemed.metadata["spend"]["audience"] == "https://shop.example/signup"
      assert redeemed.metadata["spend"]["nonce"] == "checkout-123"

      persisted = Repo.get!(Attestation, token_attestation.id)
      assert persisted.metadata["spend"]["audience"] == "https://shop.example/signup"

      assert {:error, :already_redeemed} =
               Attestations.redeem_anonymous_effort_token(token_attestation.artifact, %{
                 "audience" => "https://other.example"
               })
    end

    test "stores valid gate proof metadata with the issued token" do
      {:ok, challenge} = Attestations.issue_pow_challenge(difficulty: 0)

      {:ok, token_attestation} =
        Attestations.issue_anonymous_effort_token(%{
          "challenge" => challenge["challenge"],
          "solution" => "any-solution",
          "gate_proof" => gate_proof(challenge["challenge"])
        })

      assert token_attestation.metadata["gate_proof"]["version"] == "atomine-gate-v1"

      assert token_attestation.metadata["gate_proof"]["layers"] == [
               "pow",
               "browser_instrumentation"
             ]

      checks = token_attestation.metadata["gate_proof"]["browser_instrumentation"]["checks"]

      assert Enum.map(checks, & &1["name"]) == [
               "layout.getComputedStyle",
               "canvas.toDataURL",
               "event.isTrusted",
               "navigator.webdriver",
               "dom.querySelector"
             ]
    end

    test "rejects invalid gate proof when provided" do
      {:ok, challenge} = Attestations.issue_pow_challenge(difficulty: 0)

      assert {:error, :invalid_gate_proof} =
               Attestations.issue_anonymous_effort_token(%{
                 "challenge" => challenge["challenge"],
                 "solution" => "any-solution",
                 "gate_proof" => %{
                   "version" => "atomine-gate-v1",
                   "layers" => ["pow", "browser_instrumentation"],
                   "browser_instrumentation" => %{
                     "challenge_hash" => "wrong",
                     "checks" => []
                   }
                 }
               })
    end

    test "requires gate proof for anonymous effort tokens" do
      {:ok, challenge} = Attestations.issue_pow_challenge(difficulty: 0)

      assert {:error, :missing_gate_proof} =
               Attestations.issue_anonymous_effort_token(%{
                 "challenge" => challenge["challenge"],
                 "solution" => "any-solution"
               })
    end

    test "rejects invalid spend audiences" do
      {:ok, challenge} = Attestations.issue_pow_challenge(difficulty: 0)

      {:ok, token_attestation} =
        Attestations.issue_anonymous_effort_token(%{
          "challenge" => challenge["challenge"],
          "solution" => "any-solution",
          "gate_proof" => gate_proof(challenge["challenge"])
        })

      assert {:error, :invalid_audience} =
               Attestations.redeem_anonymous_effort_token(token_attestation.artifact, %{
                 "audience" => ""
               })
    end
  end

  defp gate_proof(challenge) do
    %{
      "version" => "atomine-gate-v1",
      "layers" => ["pow", "browser_instrumentation"],
      "browser_instrumentation" => %{
        "challenge_hash" => sha256_base64url(challenge),
        "checks" =>
          Enum.map(
            ~w(layout.getComputedStyle canvas.toDataURL event.isTrusted navigator.webdriver dom.querySelector),
            &%{"name" => &1, "ok" => true, "duration_ms" => 1}
          ),
        "signals" => %{"user_agent_hash" => sha256_base64url("test-browser")}
      }
    }
  end

  defp sha256_base64url(value) do
    :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
  end
end
