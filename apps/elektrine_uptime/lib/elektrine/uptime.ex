defmodule Elektrine.Uptime do
  @moduledoc """
  Core context for Elektrine's uptime monitor.

  Users register HTTP/TCP/ping monitors; a background scheduler probes them on an
  interval, records results into an append-only check history, and tracks downtime
  incidents. All target validation flows through `Elektrine.Security.URLValidator`
  so a monitor can't be turned into an internal port-scanner (SSRF).
  """

  import Ecto.Query, warn: false

  alias Elektrine.Accounts.User
  alias Elektrine.Repo
  alias Elektrine.Uptime.Check
  alias Elektrine.Uptime.Incident
  alias Elektrine.Uptime.Monitor

  ## CRUD (user-scoped)

  def list_monitors(%User{id: user_id}), do: list_monitors(user_id)

  def list_monitors(user_id) when is_integer(user_id) do
    Monitor
    |> where(user_id: ^user_id)
    |> order_by([m], asc: m.name, asc: m.id)
    |> Repo.all()
  end

  def list_monitors(_), do: []

  def get_monitor(id, user_id) when is_integer(id) and is_integer(user_id) do
    Monitor
    |> where([m], m.id == ^id and m.user_id == ^user_id)
    |> Repo.one()
  end

  def get_monitor(_, _), do: nil

  def get_monitor!(id), do: Repo.get!(Monitor, id)

  def create_monitor(%User{id: user_id}, attrs), do: create_monitor(user_id, attrs)

  def create_monitor(user_id, attrs) when is_integer(user_id) and is_map(attrs) do
    %Monitor{}
    |> Monitor.changeset(Map.put(stringify_keys(attrs), "user_id", user_id))
    |> Repo.insert()
  end

  def create_monitor(_, _), do: {:error, :invalid_attributes}

  def update_monitor(%Monitor{} = monitor, attrs) when is_map(attrs) do
    monitor
    |> Monitor.changeset(attrs)
    |> Repo.update()
  end

  def delete_monitor(%Monitor{} = monitor), do: Repo.delete(monitor)

  def change_monitor(%Monitor{} = monitor, attrs \\ %{}), do: Monitor.changeset(monitor, attrs)

  def new_monitor_changeset(%User{id: user_id}), do: new_monitor_changeset(user_id)

  def new_monitor_changeset(user_id) when is_integer(user_id) do
    Monitor.changeset(%Monitor{}, %{
      "user_id" => user_id,
      "check_type" => "http",
      "interval_seconds" => 300,
      "timeout_ms" => 10_000,
      "failure_threshold" => 2
    })
  end

  def new_monitor_changeset(_), do: Monitor.changeset(%Monitor{}, %{})

  @doc """
  Monitors that are enabled and due for a check (never checked, or last checked
  more than `interval_seconds` ago). Uses the `[:enabled, :last_checked_at]` index.
  """
  def list_due_monitors do
    now = DateTime.utc_now()

    Monitor
    |> where([m], m.enabled == true)
    |> where(
      [m],
      is_nil(m.last_checked_at) or
        m.last_checked_at <=
          datetime_add(^now, fragment("- ?", m.interval_seconds), "second")
    )
    |> Repo.all()
  end

  ## Recording checks + incident transitions

  @doc """
  Records the result of a single probe and drives incident transitions in one
  transaction.

  `result` is the `Checker` contract:

      {:up, %{response_time_ms: integer, status_code: integer | nil}}
      {:down, reason_string}

  Inserts an `uptime_checks` row, recomputes the monitor's `last_status`,
  `consecutive_failures` (reset to 0 on up, +1 on down) and `last_checked_at`,
  opens/resolves the open incident, and returns
  `{:ok, %{check: ..., monitor: ..., transition: transition}}` where `transition`
  is one of:

    * `:none`      — up→up, or down below the failure threshold (no alert yet)
    * `:went_down` — `consecutive_failures` just crossed `failure_threshold`
      (alert once); opens an incident
    * `:still_down`— another failure while already past the threshold
    * `:recovered` — down→up; resolves the open incident
  """
  def record_check(%Monitor{} = monitor, result) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    {status, check_attrs} = normalize_result(result, monitor.id)

    new_failures =
      case status do
        "up" -> 0
        "down" -> (monitor.consecutive_failures || 0) + 1
      end

    transition = classify_transition(monitor, status, new_failures)

    Repo.transaction(fn ->
      {:ok, check} =
        %Check{}
        |> Check.changeset(check_attrs)
        |> Repo.insert()

      {:ok, updated_monitor} =
        monitor
        |> Monitor.update_check_state_changeset(%{
          last_status: status,
          last_checked_at: now,
          consecutive_failures: new_failures
        })
        |> Repo.update()

      apply_incident_transition(updated_monitor, transition, check_attrs[:error], now)

      %{check: check, monitor: updated_monitor, transition: transition}
    end)
  end

  defp normalize_result({:up, %{} = info}, monitor_id) do
    {"up",
     %{
       status: "up",
       monitor_id: monitor_id,
       response_time_ms: Map.get(info, :response_time_ms),
       status_code: Map.get(info, :status_code),
       error: nil
     }}
  end

  defp normalize_result({:down, reason}, monitor_id) do
    {"down",
     %{
       status: "down",
       monitor_id: monitor_id,
       response_time_ms: nil,
       status_code: nil,
       error: to_string(reason)
     }}
  end

  # Transition table:
  #   up   -> up:   :none
  #   up   -> down (below threshold):   :none
  #   up   -> down (crossing threshold): :went_down
  #   down -> down (already past threshold): :still_down
  #   down -> up:   :recovered (only when there is an open incident to resolve)
  defp classify_transition(%Monitor{} = monitor, "down", new_failures) do
    threshold = monitor.failure_threshold || 1

    cond do
      new_failures == threshold -> :went_down
      new_failures > threshold -> :still_down
      true -> :none
    end
  end

  defp classify_transition(%Monitor{} = monitor, "up", _new_failures) do
    if monitor.last_status == "down", do: :recovered, else: :none
  end

  defp apply_incident_transition(%Monitor{} = monitor, :went_down, error, now) do
    open_incident(monitor, error, now)
  end

  defp apply_incident_transition(%Monitor{} = monitor, :recovered, _error, now) do
    resolve_open_incident(monitor, now)
  end

  defp apply_incident_transition(_monitor, _transition, _error, _now), do: :ok

  @doc "The currently open (unresolved) incident for a monitor, or nil."
  def current_open_incident(monitor_id) when is_integer(monitor_id) do
    from(i in Incident,
      where: i.monitor_id == ^monitor_id and is_nil(i.resolved_at),
      limit: 1
    )
    |> Repo.one()
  end

  # Idempotent: the partial-unique open-incident index + on_conflict: :nothing
  # guarantees at most one open incident per monitor under concurrency.
  defp open_incident(%Monitor{id: monitor_id}, error, now) do
    %Incident{}
    |> Incident.changeset(%{monitor_id: monitor_id, started_at: now, last_error: error})
    |> Repo.insert(on_conflict: :nothing)
  end

  defp resolve_open_incident(%Monitor{id: monitor_id}, now) do
    case current_open_incident(monitor_id) do
      nil ->
        :ok

      %Incident{} = incident ->
        incident
        |> Ecto.Changeset.change(resolved_at: now)
        |> Repo.update()
    end
  end

  ## Stats / chart helpers (return sensible empty results without data)

  @doc """
  Per-day uptime percentage over the trailing `days` window, oldest first.
  Each entry is `%{date: Date.t(), uptime: float() | nil}` where `uptime` is nil
  when no checks were recorded that day.
  """
  def daily_uptime_series(monitor_id, days \\ 90)

  def daily_uptime_series(monitor_id, days) when is_integer(monitor_id) and days > 0 do
    start_date = Date.add(Date.utc_today(), -(days - 1))
    end_date = Date.utc_today()

    rows =
      from(c in Check,
        where: c.monitor_id == ^monitor_id and fragment("?::date", c.inserted_at) >= ^start_date,
        group_by: fragment("?::date", c.inserted_at),
        select: %{
          date: fragment("?::date", c.inserted_at),
          total: count(c.id),
          up: fragment("COUNT(*) FILTER (WHERE ? = 'up')", c.status)
        }
      )
      |> Repo.all()
      |> Map.new(fn %{date: date, total: total, up: up} -> {date, {total, up}} end)

    Date.range(start_date, end_date)
    |> Enum.map(fn date ->
      case Map.get(rows, date) do
        {total, up} when total > 0 -> %{date: date, uptime: up / total * 100.0}
        _ -> %{date: date, uptime: nil}
      end
    end)
  end

  def daily_uptime_series(_, _), do: []

  @doc """
  Recent latency samples (oldest first) as `%{at: DateTime.t(), response_time_ms: integer() | nil}`.
  """
  def latency_series(monitor_id, limit \\ 100)

  def latency_series(monitor_id, limit) when is_integer(monitor_id) and limit > 0 do
    from(c in Check,
      where: c.monitor_id == ^monitor_id,
      order_by: [desc: c.inserted_at, desc: c.id],
      limit: ^limit,
      select: %{at: c.inserted_at, response_time_ms: c.response_time_ms}
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  def latency_series(_, _), do: []

  @doc """
  Overall uptime percentage over the trailing `days` window, or `nil` when there
  are no checks in that window.
  """
  def uptime_percentage(monitor_id, days \\ 90)

  def uptime_percentage(monitor_id, days) when is_integer(monitor_id) and days > 0 do
    since = DateTime.add(DateTime.utc_now(), -days * 24 * 3600, :second)

    result =
      from(c in Check,
        where: c.monitor_id == ^monitor_id and c.inserted_at >= ^since,
        select: %{
          total: count(c.id),
          up: fragment("COUNT(*) FILTER (WHERE ? = 'up')", c.status)
        }
      )
      |> Repo.one()

    case result do
      %{total: total, up: up} when total > 0 -> up / total * 100.0
      _ -> nil
    end
  end

  def uptime_percentage(_, _), do: nil

  @doc "Most recent checks for a monitor, newest first."
  def recent_checks(monitor_id, limit \\ 50)

  def recent_checks(monitor_id, limit) when is_integer(monitor_id) and limit > 0 do
    from(c in Check,
      where: c.monitor_id == ^monitor_id,
      order_by: [desc: c.inserted_at, desc: c.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  def recent_checks(_, _), do: []

  @doc "Incidents for a monitor, most recent first."
  def list_incidents(monitor_id, limit \\ 50)

  def list_incidents(monitor_id, limit) when is_integer(monitor_id) and limit > 0 do
    from(i in Incident,
      where: i.monitor_id == ^monitor_id,
      order_by: [desc: i.started_at, desc: i.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  def list_incidents(_, _), do: []

  ## Helpers

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
