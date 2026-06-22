defmodule Elektrine.UptimeTest do
  use Elektrine.DataCase, async: true

  alias Elektrine.Accounts.User
  alias Elektrine.Uptime

  defp create_user do
    username = "u" <> (System.unique_integer([:positive]) |> Integer.to_string())

    {:ok, user} =
      %User{}
      |> User.import_changeset(%{username: username, password_hash: "x"})
      |> Repo.insert()

    user
  end

  defp create_monitor(user, attrs \\ %{}) do
    base = %{
      "name" => "mon",
      "check_type" => "http",
      "target" => "https://example.com",
      "interval_seconds" => 60,
      "failure_threshold" => 2
    }

    {:ok, monitor} = Uptime.create_monitor(user, Map.merge(base, attrs))
    monitor
  end

  describe "user scoping" do
    test "list/get only return the owner's monitors" do
      u1 = create_user()
      u2 = create_user()
      m1 = create_monitor(u1)
      _m2 = create_monitor(u2)

      assert [listed] = Uptime.list_monitors(u1)
      assert listed.id == m1.id
      assert Uptime.get_monitor(m1.id, u1.id).id == m1.id
      assert Uptime.get_monitor(m1.id, u2.id) == nil
    end
  end

  describe "list_due_monitors/0" do
    test "includes never-checked and overdue, excludes recently-checked and disabled" do
      user = create_user()
      never = create_monitor(user)

      overdue = create_monitor(user)

      {:ok, overdue} =
        overdue
        |> Ecto.Changeset.change(
          last_checked_at:
            DateTime.utc_now()
            |> DateTime.add(-120, :second)
            |> DateTime.truncate(:second)
        )
        |> Repo.update()

      recent = create_monitor(user)

      {:ok, _recent} =
        recent
        |> Ecto.Changeset.change(last_checked_at: DateTime.truncate(DateTime.utc_now(), :second))
        |> Repo.update()

      disabled = create_monitor(user, %{"enabled" => false})
      {:ok, _disabled} = Uptime.update_monitor(disabled, %{"enabled" => false})

      due_ids = Uptime.list_due_monitors() |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.member?(due_ids, never.id)
      assert MapSet.member?(due_ids, overdue.id)
      refute MapSet.member?(due_ids, recent.id)
      refute MapSet.member?(due_ids, disabled.id)
    end
  end

  describe "record_check/2 transition table" do
    test "up -> up is :none with no incident" do
      monitor = create_monitor(create_user())

      {:ok, %{transition: :none, monitor: m}} =
        Uptime.record_check(monitor, {:up, %{response_time_ms: 10, status_code: 200}})

      assert m.last_status == "up"
      assert m.consecutive_failures == 0
      assert Uptime.current_open_incident(m.id) == nil
    end

    test "down below threshold is :none and opens no incident" do
      monitor = create_monitor(create_user(), %{"failure_threshold" => 2})

      {:ok, %{transition: :none, monitor: m}} =
        Uptime.record_check(monitor, {:down, "boom"})

      assert m.last_status == "down"
      assert m.consecutive_failures == 1
      assert Uptime.current_open_incident(m.id) == nil
    end

    test "crossing threshold is :went_down with exactly one open incident" do
      monitor = create_monitor(create_user(), %{"failure_threshold" => 2})

      {:ok, %{transition: :none, monitor: m1}} =
        Uptime.record_check(monitor, {:down, "boom"})

      {:ok, %{transition: :went_down, monitor: m2}} =
        Uptime.record_check(m1, {:down, "boom"})

      assert m2.consecutive_failures == 2
      assert %{resolved_at: nil} = Uptime.current_open_incident(m2.id)

      open_count =
        Repo.aggregate(
          from(i in Elektrine.Uptime.Incident,
            where: i.monitor_id == ^m2.id and is_nil(i.resolved_at)
          ),
          :count
        )

      assert open_count == 1
    end

    test "further failure past threshold is :still_down and opens no new incident" do
      monitor = create_monitor(create_user(), %{"failure_threshold" => 1})

      {:ok, %{transition: :went_down, monitor: m1}} =
        Uptime.record_check(monitor, {:down, "boom"})

      {:ok, %{transition: :still_down, monitor: m2}} =
        Uptime.record_check(m1, {:down, "boom"})

      assert m2.consecutive_failures == 2

      open_count =
        Repo.aggregate(
          from(i in Elektrine.Uptime.Incident,
            where: i.monitor_id == ^m2.id and is_nil(i.resolved_at)
          ),
          :count
        )

      assert open_count == 1
    end

    test "down -> up is :recovered and resolves the open incident" do
      monitor = create_monitor(create_user(), %{"failure_threshold" => 1})

      {:ok, %{transition: :went_down, monitor: m1}} =
        Uptime.record_check(monitor, {:down, "boom"})

      assert %{resolved_at: nil} = Uptime.current_open_incident(m1.id)

      {:ok, %{transition: :recovered, monitor: m2}} =
        Uptime.record_check(m1, {:up, %{response_time_ms: 5, status_code: 200}})

      assert m2.last_status == "up"
      assert m2.consecutive_failures == 0
      assert Uptime.current_open_incident(m2.id) == nil

      assert %{resolved_at: resolved_at} =
               Repo.one(from(i in Elektrine.Uptime.Incident, where: i.monitor_id == ^m2.id))

      assert resolved_at != nil
    end

    test "partial-unique index blocks a second open incident" do
      monitor = create_monitor(create_user(), %{"failure_threshold" => 1})

      {:ok, _} = Uptime.record_check(monitor, {:down, "boom"})

      attrs = %{
        monitor_id: monitor.id,
        started_at: DateTime.truncate(DateTime.utc_now(), :second)
      }

      assert {:error, changeset} =
               %Elektrine.Uptime.Incident{}
               |> Elektrine.Uptime.Incident.changeset(attrs)
               |> Repo.insert()

      refute changeset.valid?
    end
  end
end
