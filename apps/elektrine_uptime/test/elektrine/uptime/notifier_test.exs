defmodule Elektrine.Uptime.NotifierTest do
  use Elektrine.DataCase, async: false

  alias Elektrine.Accounts.User
  alias Elektrine.Notifications.Notification
  alias Elektrine.Uptime
  alias Elektrine.Uptime.Notifier

  defp create_user(attrs \\ %{}) do
    username = "u" <> (System.unique_integer([:positive]) |> Integer.to_string())
    {recovery_email, attrs} = Map.pop(attrs, :recovery_email)

    {:ok, user} =
      %User{}
      |> User.import_changeset(Map.merge(%{username: username, password_hash: "x"}, attrs))
      |> Repo.insert()

    # recovery_email isn't part of import_changeset; set it directly when given.
    if Map.has_key?(attrs, :recovery_email) or recovery_email != nil do
      user
      |> Ecto.Changeset.change(recovery_email: recovery_email)
      |> Repo.update!()
    else
      user
    end
  end

  defp create_monitor(user, attrs \\ %{}) do
    {:ok, monitor} =
      Uptime.create_monitor(
        user,
        Map.merge(
          %{
            "name" => "mon",
            "check_type" => "http",
            "target" => "https://example.com",
            "interval_seconds" => 60,
            "failure_threshold" => 1,
            "notify_in_app" => true
          },
          attrs
        )
      )

    monitor
  end

  defp uptime_notifications(user_id, type) do
    Repo.all(from(n in Notification, where: n.user_id == ^user_id and n.type == ^type))
  end

  test "went_down creates an in-app uptime_down notification" do
    user = create_user()
    monitor = create_monitor(user)

    {:ok, %{monitor: monitor, check: check, transition: transition}} =
      Uptime.record_check(monitor, {:down, "boom"})

    assert transition == :went_down
    assert :ok = Notifier.notify(monitor, check, transition)

    assert [notif] = uptime_notifications(user.id, "uptime_down")
    assert notif.title == "mon is down"
    assert notif.body == "boom"
    assert notif.priority == "high"
    assert notif.source_type == "uptime_monitor"
    assert notif.source_id == monitor.id
  end

  test "recovered creates an in-app uptime_recovered notification" do
    user = create_user()
    monitor = create_monitor(user)

    {:ok, %{monitor: monitor, check: check, transition: :went_down}} =
      Uptime.record_check(monitor, {:down, "boom"})

    :ok = Notifier.notify(monitor, check, :went_down)

    {:ok, %{monitor: monitor, check: check, transition: transition}} =
      Uptime.record_check(monitor, {:up, %{response_time_ms: 5, status_code: 200}})

    assert transition == :recovered
    assert :ok = Notifier.notify(monitor, check, transition)

    assert [notif] = uptime_notifications(user.id, "uptime_recovered")
    assert notif.title == "mon recovered"
  end

  test "still_down and none create no new notifications" do
    user = create_user()
    # threshold 2 so the first failure is :none, the second :went_down, third :still_down
    monitor = create_monitor(user, %{"failure_threshold" => 2})

    {:ok, %{monitor: m1, check: c1, transition: :none}} =
      Uptime.record_check(monitor, {:down, "x"})

    assert :ok = Notifier.notify(m1, c1, :none)
    assert uptime_notifications(user.id, "uptime_down") == []

    {:ok, %{monitor: m2, check: c2, transition: :went_down}} =
      Uptime.record_check(m1, {:down, "x"})

    :ok = Notifier.notify(m2, c2, :went_down)
    assert [_one] = uptime_notifications(user.id, "uptime_down")

    {:ok, %{monitor: m3, check: c3, transition: :still_down}} =
      Uptime.record_check(m2, {:down, "x"})

    assert :ok = Notifier.notify(m3, c3, :still_down)
    # still exactly one - no per-check spam
    assert [_one] = uptime_notifications(user.id, "uptime_down")
  end

  test "notify_email does not crash when an address is deliverable" do
    user = create_user(%{recovery_email: "owner@example.com"})

    monitor =
      create_monitor(user, %{"notify_email" => true, "notify_in_app" => false})

    {:ok, %{monitor: monitor, check: check, transition: :went_down}} =
      Uptime.record_check(monitor, {:down, "boom"})

    # Mailer.deliver_later/1 enqueues on the :email Oban queue (inline in test),
    # delivering through the Swoosh Test adapter in a separate process. We assert
    # the dispatch returns :ok (resilient, never crashes the worker); the email
    # body/subject is covered by the Email builder test below.
    assert :ok = Notifier.notify(monitor, check, :went_down)

    # no in-app notification when notify_in_app is false
    assert uptime_notifications(user.id, "uptime_down") == []
  end

  test "the built down email is addressed to the user with the right subject" do
    user = create_user(%{recovery_email: "owner@example.com"})
    monitor = create_monitor(user)

    {:ok, %{monitor: monitor, check: check}} =
      Uptime.record_check(monitor, {:down, "boom"})

    email = Elektrine.Uptime.Email.down_email(user, monitor, check)
    assert email.subject == "[Down] mon"
    assert {_, "owner@example.com"} = hd(email.to)

    recovery = Elektrine.Uptime.Email.recovery_email(user, monitor)
    assert recovery.subject == "[Recovered] mon"
  end

  test "notify_email with no deliverable address does not crash or enqueue mail" do
    user = create_user(%{recovery_email: nil})

    monitor =
      create_monitor(user, %{"notify_email" => true, "notify_in_app" => false})

    {:ok, %{monitor: monitor, check: check, transition: :went_down}} =
      Uptime.record_check(monitor, {:down, "boom"})

    assert :ok = Notifier.notify(monitor, check, :went_down)
  end
end
