defmodule Elektrine.DNS.AuthorityCacheTestDKIM do
  def generate_domain_key_material do
    %{selector: "default", public_key: "PUBLICKEY", private_key: "PRIVATEKEY"}
  end

  def public_key_dns_value(key), do: key
  def mx_host, do: "mail.example.com"
  def sync_domain(_domain, _selector, _private_key), do: :ok
end

defmodule Elektrine.DNS.AuthorityCacheTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.AccountsFixtures
  alias Elektrine.DNS
  alias Elektrine.DNS.Query
  alias Elektrine.DNS.ZoneCache

  setup do
    old_dns = Application.get_env(:elektrine, :dns, [])
    old_dkim = Application.get_env(:elektrine, :managed_dns_dkim_module)

    Application.put_env(
      :elektrine,
      :dns,
      Keyword.merge(old_dns,
        nameservers: ["ns1.cache-test.example", "ns2.cache-test.example"]
      )
    )

    Application.put_env(
      :elektrine,
      :managed_dns_dkim_module,
      Elektrine.DNS.AuthorityCacheTestDKIM
    )

    ensure_zone_cache_started()
    ZoneCache.refresh()

    on_exit(fn ->
      Application.put_env(:elektrine, :dns, old_dns)
      Application.put_env(:elektrine, :managed_dns_dkim_module, old_dkim)

      if Process.whereis(ZoneCache) do
        ZoneCache.refresh()
      end
    end)

    :ok
  end

  test "new zones are served authoritatively without a restart" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})

    response = Query.answer(build_query(zone.domain, 2))

    assert header(response).rcode == 0
    assert header(response).aa == 1
    assert header(response).ancount == 2
  end

  test "managed mail records are served authoritatively right after apply" do
    user = AccountsFixtures.user_fixture()
    {:ok, zone} = DNS.create_zone(user, %{"domain" => unique_domain()})
    assert {:ok, _config} = DNS.apply_zone_service(zone, "mail")

    response = Query.answer(build_query("_dmarc." <> zone.domain, 16))

    assert header(response).rcode == 0
    assert header(response).aa == 1
    assert header(response).ancount == 1
  end

  defp ensure_zone_cache_started do
    case Process.whereis(ZoneCache) do
      nil -> start_supervised!(ZoneCache)
      _pid -> :ok
    end
  end

  defp build_query(name, type) do
    <<0x12, 0x34, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      encode_name(name)::binary, type::16, 1::16>>
  end

  defp encode_name(name) do
    name
    |> String.split(".", trim: true)
    |> Enum.map_join(fn label -> <<byte_size(label)>> <> label end)
    |> Kernel.<>(<<0>>)
  end

  defp header(
         <<_id::16, flags::16, _qd::16, ancount::16, _nscount::16, _arcount::16, _rest::binary>>
       ) do
    %{
      ancount: ancount,
      rcode: Bitwise.band(flags, 0x000F),
      aa: Bitwise.band(Bitwise.bsr(flags, 10), 1)
    }
  end

  defp unique_domain do
    "cache#{System.unique_integer([:positive])}.example.com"
  end
end
