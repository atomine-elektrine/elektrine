defmodule Elektrine.Accounts.CapabilitiesTest do
  use Elektrine.DataCase, async: false

  alias Atomine.Personhood
  alias Elektrine.Accounts.Capabilities
  alias Elektrine.AccountsFixtures
  alias Elektrine.Repo

  test "email limits come from the central capability policy" do
    user = AccountsFixtures.user_fixture()

    assert %{
             tier: :day_1,
             minute_limit: 1,
             hour_limit: 5,
             day_limit: 10,
             recipient_limit: 3
           } = Capabilities.email_limits(user)

    user = Ecto.Changeset.change(user, %{trust_level: 2}) |> Repo.update!()

    assert %{
             tier: :tl2,
             minute_limit: 10,
             hour_limit: 100,
             day_limit: 500,
             recipient_limit: 100
           } = Capabilities.email_limits(user)
  end

  test "verified proof reputation raises effective email tier without mutating trust level" do
    user = AccountsFixtures.user_fixture()

    {:ok, dns_proof} = Personhood.create_proof(user, %{kind: "dns", subject: unique_domain()})
    {:ok, _verified_dns} = Personhood.verify_proof(dns_proof)

    assert %{tier: :tl1, day_limit: 200, recipient_limit: 50} = Capabilities.email_limits(user)
    assert Repo.reload!(user).trust_level == 0

    {:ok, web_proof} =
      Personhood.create_proof(user, %{kind: "web", subject: "https://#{unique_domain()}/proof"})

    {:ok, _verified_web} = Personhood.verify_proof(web_proof)

    assert %{tier: :tl2, day_limit: 500, recipient_limit: 100} = Capabilities.email_limits(user)

    snapshot = Capabilities.snapshot(user)

    assert snapshot.trust_level == 0
    assert snapshot.effective_trust_level == 2
    assert snapshot.capabilities.email.tier == :tl2
  end

  test "credit gates require credits only for low-trust users when enabled" do
    previous_config = Application.get_env(:atomine, :credits, [])

    on_exit(fn -> Application.put_env(:atomine, :credits, previous_config) end)

    Application.put_env(:atomine, :credits, email_gate_enabled: true, dm_gate_enabled: true)

    user = AccountsFixtures.user_fixture()

    assert :required = Capabilities.email_credit_requirement(user)
    assert :required = Capabilities.first_dm_credit_requirement(user)

    trusted_user = Ecto.Changeset.change(user, %{trust_level: 1}) |> Repo.update!()

    assert :required = Capabilities.email_credit_requirement(trusted_user)
    assert :free = Capabilities.first_dm_credit_requirement(trusted_user)

    high_trust_user = Ecto.Changeset.change(trusted_user, %{trust_level: 3}) |> Repo.update!()

    assert :free = Capabilities.email_credit_requirement(high_trust_user)
    assert :free = Capabilities.first_dm_credit_requirement(high_trust_user)

    admin_user = Ecto.Changeset.change(user, %{is_admin: true}) |> Repo.update!()

    assert :free = Capabilities.email_credit_requirement(admin_user)
    assert :free = Capabilities.first_dm_credit_requirement(admin_user)

    proof_backed_user = AccountsFixtures.user_fixture()

    {:ok, proof} =
      Personhood.create_proof(proof_backed_user, %{kind: "dns", subject: unique_domain()})

    {:ok, _verified} = Personhood.verify_proof(proof)

    assert :required = Capabilities.email_credit_requirement(proof_backed_user)
    assert :free = Capabilities.first_dm_credit_requirement(proof_backed_user)
  end

  test "snapshot ties trust, reputation, credits, email, vpn, and invites together" do
    user = AccountsFixtures.user_fixture()
    snapshot = Capabilities.snapshot(user)

    assert snapshot.trust_level == 0
    assert snapshot.reputation.score >= 0
    assert snapshot.proofs.verified_count >= 0
    assert is_map(snapshot.credits.balances)
    assert snapshot.capabilities.email.tier == :day_1
    assert snapshot.capabilities.vpn.allowed == true
    assert snapshot.capabilities.invites.self_service_allowed == false
  end

  defp unique_domain do
    "proof-#{System.unique_integer([:positive])}.example.com"
  end
end
