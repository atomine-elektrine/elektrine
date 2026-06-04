defmodule ElektrineWeb.ProfileNavigationTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Accounts.User
  alias ElektrineWeb.ProfileNavigation

  setup do
    previous_email = Application.get_env(:elektrine, :email)
    previous_profile_base_domains = Application.get_env(:elektrine, :profile_base_domains)

    Application.put_env(:elektrine, :email, domain: "elektrine.com")
    Application.put_env(:elektrine, :profile_base_domains, ["elektrine.com"])

    on_exit(fn ->
      Application.put_env(:elektrine, :email, previous_email)

      if is_nil(previous_profile_base_domains) do
        Application.delete_env(:elektrine, :profile_base_domains)
      else
        Application.put_env(:elektrine, :profile_base_domains, previous_profile_base_domains)
      end
    end)

    :ok
  end

  test "profile_url uses main-domain path for path-mode users" do
    user =
      Elektrine.Repo.insert!(%User{
        username: "profile_nav_path",
        handle: "profile_nav_path",
        password_hash: "hash",
        built_in_subdomain_mode: "path"
      })

    assert ProfileNavigation.profile_url(%{"user_id" => Integer.to_string(user.id)}) ==
             "https://elektrine.com/profile_nav_path"

    assert ProfileNavigation.profile_url(%{"handle" => "profile_nav_path"}) ==
             "https://elektrine.com/profile_nav_path"
  end

  test "profile_url uses handle subdomain for platform-mode users" do
    user =
      Elektrine.Repo.insert!(%User{
        username: "profile_nav_platform",
        handle: "profile_nav_platform",
        password_hash: "hash",
        built_in_subdomain_mode: "platform"
      })

    assert ProfileNavigation.profile_url(%{"user_id" => Integer.to_string(user.id)}) ==
             "https://profile_nav_platform.elektrine.com"
  end
end
