defmodule Atomine.PersonhoodTest do
  use Elektrine.DataCase, async: true

  alias Atomine.Personhood
  alias Atomine.Proof
  alias Elektrine.Repo

  import Elektrine.AccountsFixtures

  describe "create_proof/2" do
    test "creates a pending proof with a generated challenge" do
      user = user_fixture()

      assert {:ok, proof} =
               Personhood.create_proof(user, %{
                 kind: "web",
                 subject: "https://example.com/.well-known/elektrine.txt",
                 evidence_url: "https://example.com/.well-known/elektrine.txt"
               })

      assert proof.status == "pending"
      assert proof.kind == "web"
      assert proof.claim_type == "positive"
      assert proof.proof_mode == "snapshot"
      assert proof.live_status == nil
      assert proof.verification_method == "page"
      assert proof.score_weight == 20
      assert proof.challenge =~ "Atomine personhood proof"
      assert proof.challenge =~ "web:"
      assert proof.metadata["verification_snippet"] == proof.challenge
      assert Personhood.page_snippet(proof) == proof.challenge
    end

    test "prevents duplicate active proofs for the same subject" do
      user = user_fixture()
      attrs = %{kind: "dns", subject: "example.com"}

      assert {:ok, _proof} = Personhood.create_proof(user, attrs)
      assert {:error, changeset} = Personhood.create_proof(user, attrs)
      assert %{subject: ["already has an active proof for this subject"]} = errors_on(changeset)
    end

    test "creates DNS claims with TXT record instructions" do
      user = user_fixture()
      {:ok, proof} = Personhood.create_proof(user, %{kind: "dns", subject: "example.com"})

      assert proof.verification_method == "dns"
      assert {"_atomine", challenge} = Personhood.dns_txt_record(proof)
      assert challenge == proof.challenge
    end

    test "creates live proofs that are stale until first successful check" do
      user = user_fixture()

      {:ok, proof} =
        Personhood.create_proof(user, %{
          kind: "web",
          subject: "https://example.com/profile",
          proof_mode: "live"
        })

      assert proof.proof_mode == "live"
      assert proof.live_status == "stale"
      assert proof.next_check_at == nil
    end

    test "creates negative assertions that cannot affect personhood score" do
      user = user_fixture()

      assert {:ok, assertion} =
               Personhood.create_negative_assertion(user, %{
                 kind: "social",
                 subject: "https://twitter.com/not-me"
               })

      assert assertion.claim_type == "negative"
      assert assertion.status == "asserted"
      assert assertion.verification_method == "none"
      assert assertion.score_weight == 0
      assert Personhood.personhood_score(user) == 0
    end
  end

  describe "review lifecycle" do
    test "verified proofs count toward score and revoked proofs stop counting" do
      user = user_fixture()
      reviewer = user_fixture()

      {:ok, proof} = Personhood.create_proof(user, %{kind: "dns", subject: "example.com"})
      assert Personhood.personhood_score(user) == 0
      assert Personhood.personhood_level(user) == :unknown

      assert {:ok, verified} = Personhood.verify_proof(proof, reviewer, "TXT record matched")
      assert verified.status == "verified"
      assert verified.checked_at
      assert verified.verified_at
      assert verified.reviewed_by_user_id == reviewer.id
      assert Personhood.personhood_score(user) == 25
      assert Personhood.personhood_level(user) == :low

      assert {:ok, revoked} = Personhood.revoke_proof(verified, reviewer, "domain changed hands")
      assert revoked.status == "revoked"
      assert revoked.revoked_at
      assert Personhood.personhood_score(user) == 0
    end

    test "live proofs can become active, stale, and inactive" do
      user = user_fixture()

      {:ok, proof} =
        Personhood.create_proof(user, %{
          kind: "dns",
          subject: "live.example.com",
          proof_mode: "live"
        })

      assert {:ok, active} = Personhood.verify_proof(proof)
      assert active.status == "verified"
      assert active.live_status == "active"
      assert active.last_seen_at
      assert active.next_check_at
      assert active.stale_at
      assert active.failed_check_count == 0
      assert Personhood.personhood_score(user) == 30

      assert {:ok, stale} = Personhood.mark_live_stale(active, "check timed out")
      assert stale.live_status == "stale"
      assert stale.failed_check_count == 1
      assert Personhood.personhood_score(user) == 12

      assert {:ok, inactive} = Personhood.mark_live_inactive(stale, "snippet missing")
      assert inactive.live_status == "inactive"
      assert inactive.failed_check_count == 2
      assert Personhood.personhood_score(user) == 0
    end

    test "manual proof can satisfy a high anti-bot gate" do
      user = user_fixture()
      {:ok, proof} = Personhood.create_proof(user, %{kind: "manual", subject: "admin-review"})
      {:ok, _verified} = Personhood.verify_proof(proof)

      assert Personhood.personhood_score(user.id) == 100
      assert Personhood.personhood_level(user.id) == :high
      assert Personhood.sufficiently_human?(user.id, 75)
    end
  end

  describe "composite scoring" do
    test "combines proof strength, diversity, age, security, history, and trust" do
      user =
        user_fixture()
        |> backdate_user(200)
        |> update_user!(%{
          login_count: 25,
          last_seen_at: DateTime.utc_now() |> DateTime.truncate(:second),
          recovery_email: "human@example.com",
          recovery_email_verified: true,
          two_factor_enabled: true,
          trust_level: 2
        })

      {:ok, dns} = Personhood.create_proof(user, %{kind: "dns", subject: "example.com"})

      {:ok, social} =
        Personhood.create_proof(user, %{kind: "social", subject: "https://social.example/@human"})

      {:ok, passkey} =
        Personhood.create_proof(user, %{kind: "passkey", subject: "credential:primary"})

      {:ok, _} = Personhood.verify_proof(dns)
      {:ok, _} = Personhood.verify_proof(social)
      {:ok, _} = Personhood.verify_proof(passkey)

      breakdown = Personhood.personhood_breakdown(user)

      assert breakdown.score == 100
      assert breakdown.level == :high
      assert breakdown.positive.proofs == 60
      assert breakdown.positive.proof_diversity == 10
      assert breakdown.positive.account_age == 16
      assert breakdown.positive.security == 20
      assert breakdown.positive.account_history == 11
      assert breakdown.positive.platform_trust == 8
      assert breakdown.verified_proof_kinds == ["dns", "passkey", "social"]
    end

    test "applies account health and rejected proof penalties" do
      user =
        user_fixture()
        |> backdate_user(30)
        |> update_user!(%{
          banned: true,
          email_sending_restricted: true,
          registered_via_onion: true
        })

      {:ok, web} = Personhood.create_proof(user, %{kind: "web", subject: "https://site.example"})

      {:ok, social} =
        Personhood.create_proof(user, %{kind: "social", subject: "https://social.example/@bot"})

      {:ok, _} = Personhood.verify_proof(web)
      {:ok, _} = Personhood.reject_proof(social)

      breakdown = Personhood.personhood_breakdown(user)

      assert breakdown.positive.proofs == 20
      assert breakdown.positive.account_age == 8
      assert breakdown.penalties.account_restrictions == 115
      assert breakdown.penalties.onion_registration == 5
      assert breakdown.penalties.proof_rejections == 10
      assert breakdown.score == 0
      assert breakdown.level == :unknown
    end
  end

  describe "list_pending_proofs/0" do
    test "returns pending proofs oldest first" do
      user = user_fixture()
      {:ok, pending} = Personhood.create_proof(user, %{kind: "web", subject: "https://a.test"})

      {:ok, verified} =
        Personhood.create_proof(user, %{kind: "social", subject: "https://b.test"})

      {:ok, _verified} = Personhood.verify_proof(verified)

      assert [^pending] = Personhood.list_pending_proofs()
      assert %Proof{} = Repo.get!(Proof, pending.id)
    end
  end

  defp backdate_user(user, days) do
    inserted_at = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.truncate(:second)

    user
    |> Ecto.Changeset.change(inserted_at: inserted_at)
    |> Repo.update!()
  end

  defp update_user!(user, attrs) do
    user
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end
end
