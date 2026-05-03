defmodule Atomine.PersonhoodTest do
  use Elektrine.DataCase, async: true

  alias Atomine.Personhood
  alias Atomine.Proof
  alias Elektrine.Accounts
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
      assert proof.challenge =~ "Atomine identity claim"
      assert proof.challenge =~ "kind=web"
      assert proof.challenge =~ "sig="
      assert proof.metadata["verification_snippet"] == proof.challenge
      assert Personhood.page_snippet(proof) == proof.challenge
    end

    test "creates signed challenge statements" do
      user = user_fixture()

      assert {:ok, proof} =
               Personhood.create_proof(user, %{
                 kind: "dns",
                 subject: "example.com"
               })

      assert proof.challenge =~ "Atomine identity claim v1"
      assert proof.challenge =~ "user=%40"
      assert proof.challenge =~ "subject=example.com"
      assert proof.challenge =~ "nonce="
      assert proof.challenge =~ "sig="
    end

    test "prevents duplicate active proofs for the same subject" do
      user = user_fixture()
      attrs = %{kind: "dns", subject: "example.com"}

      assert {:ok, _proof} = Personhood.create_proof(user, attrs)
      assert {:error, changeset} = Personhood.create_proof(user, attrs)
      assert %{subject: ["already has an active proof for this subject"]} = errors_on(changeset)
    end

    test "prevents active DNS proofs for a domain already claimed by another user" do
      first_user = user_fixture()
      second_user = user_fixture()

      assert {:ok, _proof} =
               Personhood.create_proof(first_user, %{kind: "dns", subject: "Example.COM."})

      assert {:error, changeset} =
               Personhood.create_proof(second_user, %{kind: "dns", subject: "example.com"})

      assert %{subject: ["domain already has an active DNS proof"]} = errors_on(changeset)
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

    test "uses GitHub gist verification for GitHub profile URLs" do
      user = user_fixture()

      assert {:ok, proof} =
               Personhood.create_proof(user, %{
                 kind: "social",
                 subject: "https://github.com/businessfunk"
               })

      assert proof.verification_method == "github_gist"
      assert proof.challenge =~ "kind=social"

      assert proof.challenge =~ "subject=https%3A%2F%2Fgithub.com%2Fbusinessfunk"
    end

    test "falls back to page verification for other social URLs" do
      user = user_fixture()

      assert {:ok, proof} =
               Personhood.create_proof(user, %{
                 kind: "social",
                 subject: "https://social.example/@human"
               })

      assert proof.verification_method == "page"
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

    test "check_proof reports unsupported self-check proof types" do
      user = user_fixture()
      {:ok, proof} = Personhood.create_proof(user, %{kind: "manual", subject: "admin-review"})

      assert {:error, :manual_review_required} = Personhood.check_proof(proof)
    end

    test "check_proof records failed web checks without verifying" do
      user = user_fixture()

      {:ok, proof} =
        Personhood.create_proof(user, %{
          kind: "web",
          subject: "ftp://example.com/proof"
        })

      assert {:error, {:not_found, checked}} = Personhood.check_proof(proof)
      assert checked.status == "pending"
      assert checked.checked_at
      assert checked.review_notes =~ "Web check failed"
      assert Personhood.personhood_score(user) == 0
    end

    test "check_proof blocks private web proof hosts" do
      user = user_fixture()

      {:ok, proof} =
        Personhood.create_proof(user, %{
          kind: "web",
          subject: "http://10.0.0.1/proof"
        })

      assert {:error, {:not_found, checked}} = Personhood.check_proof(proof)
      assert checked.status == "pending"
      assert checked.review_notes =~ "blocked_private_host"
    end

    test "check_proof reports failed live checks instead of returning success" do
      user = user_fixture()

      {:ok, proof} =
        Personhood.create_proof(user, %{
          kind: "web",
          subject: "ftp://example.com/proof",
          proof_mode: "live"
        })

      assert {:error, {:not_found, checked}} = Personhood.check_proof(proof)
      assert checked.status == "pending"
      assert checked.live_status == "stale"
      assert checked.failed_check_count == 1
      assert checked.checked_at
      assert checked.review_notes =~ "Web check failed"
      assert Personhood.personhood_score(user) == 0
    end

    test "lists live proofs due for scheduled recheck" do
      user = user_fixture()

      {:ok, proof} =
        Personhood.create_proof(user, %{
          kind: "dns",
          subject: "due.example.com",
          proof_mode: "live"
        })

      {:ok, verified} = Personhood.verify_proof(proof)

      due_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      verified
      |> Proof.changeset(%{next_check_at: due_at})
      |> Repo.update!()

      assert [%Proof{id: id}] = Personhood.list_due_live_proofs()
      assert id == verified.id
    end

    test "check_proof rejects tampered signed statements" do
      user = user_fixture()

      {:ok, proof} =
        Personhood.create_proof(user, %{
          kind: "web",
          subject: "https://example.com/proof"
        })

      {:ok, proof} =
        proof
        |> Proof.changeset(%{challenge: String.replace(proof.challenge, "kind=web", "kind=dns")})
        |> Repo.update()

      assert {:error, {:not_found, checked}} = Personhood.check_proof(proof)
      assert checked.status == "pending"
      assert checked.review_notes =~ "proof_kind_mismatch"
    end

    test "check_proof rejects non-GitHub profile URLs for GitHub gist verification" do
      user = user_fixture()

      {:ok, proof} =
        Personhood.create_proof(user, %{
          kind: "social",
          subject: "https://social.example/businessfunk",
          verification_method: "github_gist"
        })

      assert {:error, {:not_found, checked}} = Personhood.check_proof(proof)
      assert checked.status == "pending"
      assert checked.review_notes =~ "not_github_profile_url"
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

  describe "trust sessions" do
    test "creates a guest checkout trust session" do
      assert {:ok, session} =
               Personhood.create_trust_session(%{
                 context: "checkout",
                 merchant_id: "shop_123",
                 external_subject: "buyer@example.com",
                 signals: %{"email_verified" => true}
               })

      assert session.public_id =~ "ats_"
      assert session.user_id == nil
      assert session.context == "checkout"
      assert session.merchant_id == "shop_123"
      assert session.external_subject == "buyer@example.com"
      assert session.status == "pending"
      assert session.decision == "review"
      assert session.recommended_step_up == "proof"
      assert session.score == 0
      assert session.level == "unknown"
      assert session.expires_at
      assert Personhood.get_trust_session(session.public_id).id == session.id
    end

    test "creates a known-user trust session from the user's personhood score" do
      user = user_fixture() |> backdate_user(120)
      {:ok, proof} = Personhood.create_proof(user, %{kind: "dns", subject: "example.com"})
      {:ok, _proof} = Personhood.verify_proof(proof)

      assert {:ok, session} =
               Personhood.create_trust_session(user, %{
                 context: "checkout",
                 merchant_id: "shop_456"
               })

      assert session.user_id == user.id
      assert session.score >= 15
      assert session.decision == "step_up"
      assert session.status == "step_up"
      assert session.recommended_step_up == "passkey"
      assert session.level == "low"
    end

    test "updates and completes trust sessions" do
      {:ok, session} =
        Personhood.create_trust_session(%{
          context: "signup",
          external_subject: "new@example.com"
        })

      assert {:ok, stepped_up} =
               Personhood.update_trust_session(session, %{
                 status: "step_up",
                 decision: "step_up",
                 recommended_step_up: "passkey",
                 score: 22,
                 level: "low"
               })

      assert stepped_up.status == "step_up"
      assert stepped_up.recommended_step_up == "passkey"

      assert {:ok, completed} =
               Personhood.complete_trust_session(stepped_up, %{
                 decision: "allow",
                 recommended_step_up: "none",
                 score: 55,
                 level: "medium"
               })

      assert completed.status == "completed"
      assert completed.decision == "allow"
      assert completed.completed_at
    end

    test "lists trust sessions with filters" do
      user = user_fixture()
      {:ok, user_session} = Personhood.create_trust_session(user, %{context: "checkout"})

      {:ok, guest_session} =
        Personhood.create_trust_session(%{
          context: "signup",
          merchant_id: "shop_filter",
          external_subject: "guest@example.com"
        })

      assert [^user_session] = Personhood.list_trust_sessions(user_id: user.id)
      assert [^guest_session] = Personhood.list_trust_sessions(merchant_id: "shop_filter")
      assert guest_session in Personhood.list_trust_sessions(status: "pending")
    end
  end

  describe "connected account proofs" do
    test "creates a verified OAuth proof from a reusable connected account" do
      user = user_fixture()

      {:ok, connected_account} =
        Accounts.upsert_connected_account(user, %{
          provider: "github",
          provider_account_id: "12345",
          username: "octo",
          display_name: "Octo",
          profile_url: "https://github.com/octo"
        })

      assert {:ok, proof} = Personhood.verify_connected_account_proof(connected_account)
      assert proof.status == "verified"
      assert proof.verification_method == "oauth"
      assert proof.subject == "oauth:github:12345"
      assert proof.evidence_url == "https://github.com/octo"
      assert proof.metadata["connected_account_id"] == connected_account.id
      assert Personhood.personhood_score(user) > 0
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
