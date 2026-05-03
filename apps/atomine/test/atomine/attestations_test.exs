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
          "challenge" => challenge.challenge,
          "solution" => "any-solution"
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

    test "rejects invalid spend audiences" do
      {:ok, challenge} = Attestations.issue_pow_challenge(difficulty: 0)

      {:ok, token_attestation} =
        Attestations.issue_anonymous_effort_token(%{
          "challenge" => challenge.challenge,
          "solution" => "any-solution"
        })

      assert {:error, :invalid_audience} =
               Attestations.redeem_anonymous_effort_token(token_attestation.artifact, %{
                 "audience" => ""
               })
    end
  end
end
