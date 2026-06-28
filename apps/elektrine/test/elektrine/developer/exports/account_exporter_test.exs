defmodule Elektrine.Developer.Exports.AccountExporterTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.Developer.Exports.AccountExporter
  alias Elektrine.Domains
  alias Elektrine.Profiles

  test "account export includes OwnRoot recovery metadata" do
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
           } = data["own_root"]

    assert provider == Domains.public_base_url()

    exported_domain = Enum.find(domains, &(&1["domain"] == built_in_domain))

    assert exported_domain["subject"] == "domain:#{built_in_domain}"
    assert exported_domain["did"] == "did:web:#{built_in_domain}"
    assert exported_domain["own_root"]["subject"] == "domain:#{built_in_domain}"
    assert exported_domain["did_document"]["id"] == "did:web:#{built_in_domain}"
    assert exported_domain["migration"]["own_root"] =~ "/.well-known/own-root"
    assert [identity] = exported_domain["own_root"]["per_site_identities"]["identities"]
    assert identity["site_key"] == "hn"
    assert identity["domain"] == "hn.#{built_in_domain}"
    assert identity["subject"] == "domain:hn.#{built_in_domain}"
  end
end
