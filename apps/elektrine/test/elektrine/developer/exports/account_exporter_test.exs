defmodule Elektrine.Developer.Exports.AccountExporterTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Developer.Exports.AccountExporter
  alias Elektrine.Domains
  alias Elektrine.Profiles

  test "account export includes domain account recovery metadata" do
    user = user_fixture(%{username: "exportdomain", handle: "exportdomain"})
    built_in_domain = "exportdomain.#{Domains.default_profile_domain()}"

    assert {:ok, _identity} =
             Profiles.create_per_site_identity(user, %{
               "site_key" => "hn",
               "base_domain" => built_in_domain
             })

    file_path =
      Path.join(System.tmp_dir!(), "account-export-#{System.unique_integer([:positive])}.json")

    on_exit(fn -> File.rm(file_path) end)

    assert {:ok, _count} = AccountExporter.export(user.id, file_path, "json")

    data =
      file_path
      |> File.read!()
      |> Jason.decode!()

    assert %{
             "provider" => provider,
             "portable_root" => "dns",
             "domains" => domains
           } = data["domain_account"]

    assert provider == Domains.public_base_url()

    exported_domain = Enum.find(domains, &(&1["domain"] == built_in_domain))

    assert exported_domain["subject"] == "domain:#{built_in_domain}"
    assert exported_domain["did"] == "did:web:#{built_in_domain}"
    assert exported_domain["domain_account"]["subject"] == "domain:#{built_in_domain}"
    assert exported_domain["did_document"]["id"] == "did:web:#{built_in_domain}"
    assert is_binary(exported_domain["migration"]["domain_account"])

    assert [identity] = exported_domain["domain_account"]["per_site_identities"]["identities"]
    assert identity["site_key"] == "hn"
    assert identity["domain"] == "hn.#{built_in_domain}"
    assert identity["subject"] == "domain:hn.#{built_in_domain}"
  end
end
