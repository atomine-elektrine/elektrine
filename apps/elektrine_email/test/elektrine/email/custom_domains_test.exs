defmodule Elektrine.Email.CustomDomainsTest do
  use Elektrine.DataCase

  import Elektrine.AccountsFixtures

  alias Elektrine.Email
  alias Elektrine.Email.CustomDomain
  alias Elektrine.Repo

  defmodule TestTxtResolver do
    @behaviour Elektrine.Email.CustomDomains

    @impl true
    def lookup_txt(host) do
      Process.get({__MODULE__, host}, {:ok, []})
    end

    @impl true
    def lookup_mx(host) do
      Process.get({__MODULE__, {:mx, host}}, {:ok, []})
    end
  end

  defmodule MockHarakaHTTPClient do
    def request(method, url, headers, body, _opts) do
      request = %{method: method, url: url, headers: headers, body: body}
      Process.put({__MODULE__, :requests}, [request | requests()])

      case Process.get({__MODULE__, :responses}, []) do
        [response | rest] ->
          Process.put({__MODULE__, :responses}, rest)
          response

        [] ->
          {:ok, %Finch.Response{status: 200, body: Jason.encode!(%{"success" => true})}}
      end
    end

    def put_responses(responses), do: Process.put({__MODULE__, :responses}, responses)
    def clear_responses, do: Process.put({__MODULE__, :responses}, [])
    def clear_requests, do: Process.put({__MODULE__, :requests}, [])
    def requests, do: Process.get({__MODULE__, :requests}, [])
  end

  setup do
    previous_resolver = Application.get_env(:elektrine, :custom_domain_txt_resolver)
    previous_email_config = Application.get_env(:elektrine, :email, [])

    Application.put_env(:elektrine, :custom_domain_txt_resolver, TestTxtResolver)

    Application.put_env(
      :elektrine,
      :email,
      Keyword.merge(
        previous_email_config,
        custom_domain_http_client: MockHarakaHTTPClient,
        custom_domain_haraka_base_url: "https://haraka.example.test",
        custom_domain_haraka_api_key: "haraka-http-key",
        custom_domain_dkim_sync_enabled: true,
        custom_domain_mx_host: "mx.elektrine.test",
        custom_domain_spf_include: "spf.elektrine.test",
        custom_domain_dmarc_rua: "dmarc@elektrine.test"
      )
    )

    MockHarakaHTTPClient.clear_requests()
    MockHarakaHTTPClient.clear_responses()

    on_exit(fn ->
      if previous_resolver do
        Application.put_env(:elektrine, :custom_domain_txt_resolver, previous_resolver)
      else
        Application.delete_env(:elektrine, :custom_domain_txt_resolver)
      end

      Application.put_env(:elektrine, :email, previous_email_config)
    end)

    :ok
  end

  test "create_custom_domain generates DKIM material and syncs it to Haraka" do
    user = user_fixture(%{username: "dkimowner"})

    assert {:ok, custom_domain} =
             Email.create_custom_domain(user, %{"domain" => "mail.dkimowner.test"})

    assert custom_domain.dkim_selector == "default"
    assert custom_domain.dkim_public_key =~ "BEGIN PUBLIC KEY"
    assert custom_domain.dkim_private_key =~ "BEGIN RSA PRIVATE KEY"
    assert custom_domain.dkim_synced_at
    assert is_nil(custom_domain.dkim_last_error)

    [request] = MockHarakaHTTPClient.requests()
    assert request.method == :put
    assert request.url == "https://haraka.example.test/api/v1/dkim/domains/mail.dkimowner.test"

    assert Enum.any?(request.headers, fn {key, value} ->
             key == "x-api-key" and value == "haraka-http-key"
           end)

    body = Jason.decode!(request.body)
    assert body["selector"] == "default"
    assert body["private_key"] =~ "BEGIN RSA PRIVATE KEY"
  end

  test "dns_records_for_custom_domain includes MX, SPF, DKIM, and DMARC templates" do
    user = user_fixture(%{username: "dnsrecords"})
    {:ok, custom_domain} = Email.create_custom_domain(user, %{"domain" => "mail.dnsrecords.test"})

    records = Email.dns_records_for_custom_domain(custom_domain)

    assert Enum.any?(records, &(&1.label == "Ownership TXT"))
    assert Enum.any?(records, &(&1.label == "Inbound MX" and &1.host == "mail.dnsrecords.test"))

    assert Enum.any?(
             records,
             &(&1.label == "SPF" and &1.value == "v=spf1 include:spf.elektrine.test ~all")
           )

    assert Enum.any?(
             records,
             &(&1.label == "DKIM" and String.contains?(&1.host, "default._domainkey"))
           )

    assert Enum.any?(
             records,
             &(&1.label == "DMARC" and
                 &1.value ==
                   "v=DMARC1; p=quarantine; adkim=s; aspf=s; rua=mailto:dmarc@elektrine.test")
           )
  end

  test "legacy custom domains are backfilled with DKIM material when loaded" do
    user = user_fixture(%{username: "legacyowner"})

    legacy_domain =
      Repo.insert!(%CustomDomain{
        domain: "mail.legacyowner.test",
        verification_token: "legacy-token",
        status: "pending",
        user_id: user.id
      })

    loaded_domain = Email.get_custom_domain(legacy_domain.id, user.id)

    assert loaded_domain.dkim_selector == "default"
    assert loaded_domain.dkim_public_key =~ "BEGIN PUBLIC KEY"
    assert loaded_domain.dkim_private_key =~ "BEGIN RSA PRIVATE KEY"
  end

  test "create_custom_domain keeps the domain when Haraka sync fails" do
    MockHarakaHTTPClient.put_responses([
      {:ok, %Finch.Response{status: 503, body: Jason.encode!(%{"error" => "unavailable"})}}
    ])

    user = user_fixture(%{username: "syncfail"})

    assert {:ok, custom_domain} =
             Email.create_custom_domain(user, %{"domain" => "mail.syncfail.test"})

    assert is_nil(custom_domain.dkim_synced_at)
    assert custom_domain.dkim_last_error =~ "503"
    assert custom_domain.dkim_last_error =~ "unavailable"
    assert Email.get_custom_domain(custom_domain.id, user.id).domain == "mail.syncfail.test"
  end

  test "delete_custom_domain removes DKIM material from Haraka" do
    user = user_fixture(%{username: "deletesync"})

    assert {:ok, custom_domain} =
             Email.create_custom_domain(user, %{"domain" => "mail.deletesync.test"})

    MockHarakaHTTPClient.clear_requests()

    assert {:ok, _deleted_domain} = Email.delete_custom_domain(custom_domain)

    [request] = MockHarakaHTTPClient.requests()
    assert request.method == :delete
    assert request.url == "https://haraka.example.test/api/v1/dkim/domains/mail.deletesync.test"
    assert request.body == ""
  end

  test "verify_custom_domain marks a domain verified when the TXT record matches" do
    user = user_fixture(%{username: "domainowner"})

    {:ok, custom_domain} =
      Email.create_custom_domain(user, %{"domain" => "mail.domainowner.test"})

    Process.put(
      {TestTxtResolver, Email.verification_host(custom_domain)},
      {:ok, [Email.verification_value(custom_domain)]}
    )

    Process.put(
      {TestTxtResolver, {:mx, custom_domain.domain}},
      {:ok, ["mx.elektrine.test"]}
    )

    assert {:ok, verified_domain} = Email.verify_custom_domain(custom_domain)
    assert verified_domain.status == "verified"
    assert "mail.domainowner.test" in Elektrine.Domains.available_email_domains_for_user(user)
  end

  test "verify_custom_domain stays pending when the MX record is missing" do
    user = user_fixture(%{username: "missingmx"})

    {:ok, custom_domain} =
      Email.create_custom_domain(user, %{"domain" => "mail.missingmx.test"})

    Process.put(
      {TestTxtResolver, Email.verification_host(custom_domain)},
      {:ok, [Email.verification_value(custom_domain)]}
    )

    Process.put(
      {TestTxtResolver, {:mx, custom_domain.domain}},
      {:ok, ["mx.other-provider.test"]}
    )

    assert {:ok, pending_domain} = Email.verify_custom_domain(custom_domain)
    assert pending_domain.status == "pending"
    assert pending_domain.last_error == "Inbound MX record not found: expected mx.elektrine.test"
  end

  test "verified custom domains resolve to the owner's mailbox and support aliases" do
    user = user_fixture(%{username: "brandmail"})
    {:ok, mailbox} = Email.ensure_user_has_mailbox(user)
    {:ok, custom_domain} = Email.create_custom_domain(user, %{"domain" => "mail.brandmail.test"})

    Process.put(
      {TestTxtResolver, Email.verification_host(custom_domain)},
      {:ok, [Email.verification_value(custom_domain)]}
    )

    Process.put(
      {TestTxtResolver, {:mx, custom_domain.domain}},
      {:ok, ["mx.elektrine.test"]}
    )

    assert {:ok, _verified_domain} = Email.verify_custom_domain(custom_domain)

    assert {:ok, alias} =
             Email.create_alias(%{
               username: "sales",
               domain: "mail.brandmail.test",
               user_id: user.id
             })

    assert Email.get_mailbox_by_email("brandmail@mail.brandmail.test").id == mailbox.id

    assert match?(
             {:ok, _},
             Email.verify_email_ownership("brandmail@mail.brandmail.test", user.id)
           )

    assert Email.get_alias_by_email("sales+launch@mail.brandmail.test").id == alias.id

    other_user = user_fixture(%{username: "someoneelse"})

    assert {:error, :unsupported_domain} =
             Email.verify_email_ownership("someoneelse@mail.brandmail.test", other_user.id)
  end

  test "deleting a preferred custom domain resets the user's preferred email domain" do
    user = user_fixture(%{username: "preferredcustom"})

    {:ok, custom_domain} =
      Email.create_custom_domain(user, %{"domain" => "mail.preferredcustom.test"})

    Process.put(
      {TestTxtResolver, Email.verification_host(custom_domain)},
      {:ok, [Email.verification_value(custom_domain)]}
    )

    Process.put(
      {TestTxtResolver, {:mx, custom_domain.domain}},
      {:ok, ["mx.elektrine.test"]}
    )

    assert {:ok, verified_domain} = Email.verify_custom_domain(custom_domain)

    assert {:ok, updated_user} =
             Elektrine.Accounts.update_user(user, %{
               preferred_email_domain: verified_domain.domain
             })

    assert updated_user.preferred_email_domain == verified_domain.domain

    assert {:ok, _deleted_domain} = Email.delete_custom_domain(verified_domain)

    reloaded_user = Elektrine.Accounts.get_user!(user.id)
    assert reloaded_user.preferred_email_domain == Elektrine.Domains.default_user_handle_domain()
  end
end
