defmodule Elektrine.Profiles.StaticSiteDeploymentTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.{AccountsFixtures, Repo, StaticSites}
  alias Elektrine.Profiles.StaticSiteDeployment
  alias Elektrine.Secrets.EncryptedString

  describe "changeset/2" do
    test "allows normal GitHub branch paths" do
      changeset =
        StaticSiteDeployment.changeset(%StaticSiteDeployment{}, %{
          user_id: 1,
          repo_owner: "octo",
          repo_name: "site",
          branch: "feature/site-redesign",
          site_dir: "auto",
          deploy_status: "idle"
        })

      assert changeset.valid?
    end

    test "rejects traversal-like GitHub branch paths" do
      for branch <- ["../main", "feature/../main", "/main", "feature//main", "feature/./main"] do
        changeset =
          StaticSiteDeployment.changeset(%StaticSiteDeployment{}, %{
            user_id: 1,
            repo_owner: "octo",
            repo_name: "site",
            branch: branch,
            site_dir: "auto",
            deploy_status: "idle"
          })

        refute changeset.valid?
        assert %{branch: [_ | _]} = errors_on(changeset)
      end
    end
  end

  test "stores GitHub webhook secrets encrypted at rest" do
    user = AccountsFixtures.user_fixture()

    assert {:ok, deployment} =
             StaticSites.upsert_github_deployment(user.id, %{
               repo_owner: "octo",
               repo_name: "site",
               branch: "main",
               site_dir: "auto"
             })

    assert is_binary(deployment.webhook_secret)

    [[stored_secret]] =
      Repo.query!("SELECT webhook_secret FROM static_site_deployments WHERE id = $1", [
        deployment.id
      ]).rows

    assert EncryptedString.encrypted?(stored_secret)
    refute stored_secret == deployment.webhook_secret
  end
end
