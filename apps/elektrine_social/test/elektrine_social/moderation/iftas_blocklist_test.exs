defmodule ElektrineSocial.Moderation.IftasBlocklistTest do
  use Elektrine.DataCase, async: true

  import Elektrine.AccountsFixtures

  alias Elektrine.ActivityPub.Instance
  alias Elektrine.Repo
  alias ElektrineSocial.Moderation.IftasBlocklist

  test "apply_payload blocks IFTAS suspend domains and silences softer domains" do
    payload = %{
      "success" => true,
      "data" => %{
        "domains" => [
          %{"domain" => "Bad.Example", "severity" => "suspend"},
          %{"domain" => "noisy.example", "severity" => "silence"}
        ]
      }
    }

    assert {:ok, %{applied: 2, removed: 0}} = IftasBlocklist.apply_payload(payload)

    bad = get_instance!("bad.example")
    noisy = get_instance!("noisy.example")

    assert bad.blocked
    assert bad.reason == "IFTAS CARIAD: suspend"
    assert bad.notes =~ "iftas:cariad"

    refute noisy.blocked
    assert noisy.silenced
    assert noisy.federated_timeline_removal
  end

  test "apply_entries preserves manual admin blocks" do
    admin = user_fixture()

    manual =
      %Instance{}
      |> Instance.changeset(%{
        domain: "manual.example",
        blocked: true,
        reason: "Manual admin block",
        blocked_by_id: admin.id
      })
      |> Repo.insert!()

    result =
      IftasBlocklist.apply_entries([%{"domain" => "manual.example", "severity" => "suspend"}])

    assert result.preserved == 1

    reloaded = Repo.get!(Instance, manual.id)
    assert reloaded.blocked
    assert reloaded.reason == "Manual admin block"
  end

  test "apply_entries removes stale IFTAS-managed policies" do
    stale =
      %Instance{}
      |> Instance.changeset(%{
        domain: "stale.example",
        blocked: true,
        reason: "IFTAS CARIAD: suspend",
        notes: "iftas:cariad; threshold=66; severity=suspend"
      })
      |> Repo.insert!()

    result =
      IftasBlocklist.apply_entries([%{"domain" => "current.example", "severity" => "suspend"}])

    assert result.removed == 1

    reloaded = Repo.get!(Instance, stale.id)
    refute reloaded.blocked
    refute reloaded.silenced
    assert is_nil(reloaded.reason)
    assert is_nil(reloaded.notes)
  end

  defp get_instance!(domain) do
    Repo.get_by!(Instance, domain: domain)
  end
end
