defmodule Mix.Tasks.Messaging.Federation.LoadTest do
  @shortdoc "Runs a local messaging federation load test (events/sec, p95, gap rate)"
  @moduledoc """
  Runs a synthetic load test against `Elektrine.Messaging.Federation.receive_event/2`.

  Example:

      mix messaging.federation.load_test --events 5000 --gap-every 50
  """

  use Mix.Task

  import Ecto.Query, warn: false

  alias Elektrine.Messaging.{Federation, FederationEvent, FederationStreamPosition, Server}
  alias Elektrine.Repo

  @switches [
    events: :integer,
    gap_every: :integer,
    domain: :string
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)

    events = max(Keyword.get(opts, :events, 3_000), 10)
    gap_every = max(Keyword.get(opts, :gap_every, 50), 0)
    domain = Keyword.get(opts, :domain, "load.remote")

    server_federation_id = "https://#{domain}/federation/messaging/servers/991"
    stream_id = "server:" <> server_federation_id

    cleanup(domain, server_federation_id)

    result =
      :timer.tc(fn ->
        Enum.reduce(1..events, init_state(), fn i, state ->
          state =
            if gap_every > 0 and rem(i, gap_every) == 0 do
              # Intentionally skip expected sequence once to observe gap rate.
              run_one_event(state, domain, stream_id, state.sequence + 1, "gap-#{i}")
            else
              state
            end

          run_one_event(state, domain, stream_id, state.sequence, "ok-#{i}")
        end)
      end)

    {duration_us, state} = result
    total_seconds = duration_us / 1_000_000
    total_calls = state.calls
    applied_calls = state.applied
    gaps = state.gaps
    failures = state.failures

    p50_ms = percentile_ms(state.latencies_us, 50)
    p95_ms = percentile_ms(state.latencies_us, 95)
    p99_ms = percentile_ms(state.latencies_us, 99)

    calls_per_second = if total_seconds > 0, do: total_calls / total_seconds, else: 0.0
    applied_per_second = if total_seconds > 0, do: applied_calls / total_seconds, else: 0.0
    gap_rate = if total_calls > 0, do: gaps / total_calls * 100.0, else: 0.0

    IO.puts("Messaging Federation Load Test")
    IO.puts("================================")
    IO.puts("calls: #{total_calls}")
    IO.puts("applied: #{applied_calls}")
    IO.puts("gaps: #{gaps}")
    IO.puts("failures: #{failures}")
    IO.puts("duration_s: #{Float.round(total_seconds, 3)}")
    IO.puts("calls_per_s: #{Float.round(calls_per_second, 2)}")
    IO.puts("applied_per_s: #{Float.round(applied_per_second, 2)}")
    IO.puts("p50_ms: #{Float.round(p50_ms, 3)}")
    IO.puts("p95_ms: #{Float.round(p95_ms, 3)}")
    IO.puts("p99_ms: #{Float.round(p99_ms, 3)}")
    IO.puts("gap_rate_pct: #{Float.round(gap_rate, 2)}")
  end

  defp init_state do
    %{
      sequence: 1,
      calls: 0,
      applied: 0,
      gaps: 0,
      failures: 0,
      latencies_us: []
    }
  end

  defp run_one_event(state, domain, stream_id, sequence, label) do
    payload = event_payload(domain, stream_id, sequence, label)
    started_us = System.monotonic_time(:microsecond)
    result = Federation.receive_event(payload, domain)
    latency_us = System.monotonic_time(:microsecond) - started_us

    base = %{
      state
      | calls: state.calls + 1,
        latencies_us: [latency_us | state.latencies_us]
    }

    case result do
      {:ok, :applied} ->
        %{base | applied: base.applied + 1, sequence: sequence + 1}

      {:error, :sequence_gap} ->
        %{base | gaps: base.gaps + 1}

      {:ok, :duplicate} ->
        base

      {:ok, :stale} ->
        base

      _ ->
        %{base | failures: base.failures + 1}
    end
  end

  defp event_payload(domain, stream_id, sequence, label) do
    server_id = String.replace_prefix(stream_id, "server:", "")

    %{
      "version" => 1,
      "event_id" => "load-#{label}-#{Ecto.UUID.generate()}",
      "event_type" => "server.upsert",
      "origin_domain" => domain,
      "stream_id" => stream_id,
      "sequence" => sequence,
      "data" => %{
        "server" => %{
          "id" => server_id,
          "name" => "load-#{label}",
          "description" => "federation load test",
          "is_public" => true,
          "member_count" => sequence
        },
        "channels" => []
      }
    }
  end

  defp cleanup(domain, server_federation_id) do
    # Keep the test repeatable and avoid cross-run sequence collisions.
    Repo.delete_all(from(p in FederationStreamPosition, where: p.origin_domain == ^domain))
    Repo.delete_all(from(e in FederationEvent, where: e.origin_domain == ^domain))
    Repo.delete_all(from(s in Server, where: s.federation_id == ^server_federation_id))
  end

  defp percentile_ms([], _), do: 0.0

  defp percentile_ms(latencies_us, percentile) do
    sorted = Enum.sort(latencies_us)
    index = max(trunc(Float.ceil(length(sorted) * percentile / 100.0)) - 1, 0)
    sorted |> Enum.at(index, 0) |> Kernel./(1_000)
  end
end
