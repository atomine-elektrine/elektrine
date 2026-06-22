defmodule Elektrine.Uptime.CheckWorkerTest do
  use Elektrine.DataCase, async: false
  use Oban.Testing, repo: Elektrine.Repo

  alias Elektrine.Accounts.User
  alias Elektrine.Uptime
  alias Elektrine.Uptime.Check
  alias Elektrine.Uptime.CheckWorker

  defmodule DownStub do
    @behaviour Elektrine.Uptime.Checker.Behaviour
    @impl true
    def run(_monitor), do: {:down, "x"}
  end

  setup do
    Application.put_env(:elektrine_uptime, :checker, DownStub)
    on_exit(fn -> Application.delete_env(:elektrine_uptime, :checker) end)
    :ok
  end

  defp create_user do
    username = "u" <> (System.unique_integer([:positive]) |> Integer.to_string())

    {:ok, user} =
      %User{}
      |> User.import_changeset(%{username: username, password_hash: "x"})
      |> Repo.insert()

    user
  end

  defp create_monitor(user) do
    {:ok, monitor} =
      Uptime.create_monitor(user, %{
        "name" => "mon",
        "check_type" => "http",
        "target" => "https://example.com",
        "interval_seconds" => 60
      })

    monitor
  end

  test "records a check row and updates monitor last_status" do
    monitor = create_monitor(create_user())

    assert :ok = perform_job(CheckWorker, %{"monitor_id" => monitor.id})

    checks = Repo.all(from(c in Check, where: c.monitor_id == ^monitor.id))
    assert [%Check{status: "down", error: "x"}] = checks

    assert Uptime.get_monitor!(monitor.id).last_status == "down"
  end

  test "no-ops for a disabled monitor" do
    user = create_user()
    monitor = create_monitor(user)
    {:ok, monitor} = Uptime.update_monitor(monitor, %{"enabled" => false})

    assert :ok = perform_job(CheckWorker, %{"monitor_id" => monitor.id})

    assert Repo.aggregate(from(c in Check, where: c.monitor_id == ^monitor.id), :count) == 0
  end
end
