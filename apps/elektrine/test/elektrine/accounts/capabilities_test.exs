defmodule Elektrine.Accounts.CapabilitiesTest do
  use Elektrine.DataCase, async: false

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

  test "credit gates require credits only for low-trust users when enabled" do
    previous_config = Application.get_env(:atomine, :credits, [])

    on_exit(fn -> Application.put_env(:atomine, :credits, previous_config) end)

    Application.put_env(:atomine, :credits, email_gate_enabled: true, dm_gate_enabled: true)

    user = AccountsFixtures.user_fixture()

    assert :required = Capabilities.email_credit_requirement(user)
    assert :required = Capabilities.first_dm_credit_requirement(user)

    trusted_user = Ecto.Changeset.change(user, %{trust_level: 1}) |> Repo.update!()

    assert :free = Capabilities.email_credit_requirement(trusted_user)
    assert :free = Capabilities.first_dm_credit_requirement(trusted_user)
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
end
