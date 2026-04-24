defmodule Elektrine.DNS.TestResolver do
  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))
  end

  def lookup(domain, :in, :ns, timeout: 5_000) do
    Agent.get(__MODULE__, fn responses ->
      Map.fetch!(responses, {List.to_string(domain), 5_000})
    end)
  end
end

defmodule Elektrine.DNS.ZoneVerificationTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.DNS

  setup_all do
    start_supervised!(Elektrine.DNS.TestResolver)
    :ok
  end

  setup do
    old_dns = Application.get_env(:elektrine, :dns, [])

    Application.put_env(
      :elektrine,
      :dns,
      Keyword.merge(old_dns,
        nameservers: ["ns1.elektrine.com", "ns2.elektrine.com"],
        dns_resolver: Elektrine.DNS.TestResolver
      )
    )

    Agent.update(Elektrine.DNS.TestResolver, fn _ -> %{} end)

    on_exit(fn ->
      Application.put_env(:elektrine, :dns, old_dns)
      Agent.update(Elektrine.DNS.TestResolver, fn _ -> %{} end)
    end)

    :ok
  end

  test "verify_zone stores specific delegation mismatch details" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    put_lookup(zone.domain, [~c"ns1.wrong.test"])

    assert {:ok, updated} = DNS.verify_zone(zone)
    assert updated.status == "pending"

    assert updated.last_error ==
             "Delegation mismatch for the configured nameservers. Expected: ns1.elektrine.com, ns2.elektrine.com. Observed: ns1.wrong.test."
  end

  test "verify_zone reports when no nameservers are observed" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    put_lookup(zone.domain, [])

    assert {:ok, updated} = DNS.verify_zone(zone)

    assert updated.last_error ==
             "Delegation mismatch for the configured nameservers. Expected: ns1.elektrine.com, ns2.elektrine.com. Observed: none."
  end

  test "verify_zone marks the zone verified when delegation matches" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    put_lookup(zone.domain, [~c"ns2.elektrine.com", ~c"ns1.elektrine.com"])

    assert {:ok, updated} = DNS.verify_zone(zone)
    assert updated.status == "verified"
    assert updated.last_error == nil
  end

  defp put_lookup(domain, result) do
    Agent.update(Elektrine.DNS.TestResolver, &Map.put(&1, {domain, 5_000}, result))
  end

  defp unique_domain do
    "verify#{System.unique_integer([:positive])}.elektrine.io"
  end
end
