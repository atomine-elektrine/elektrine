defmodule Mix.Tasks.Messaging.Federation.LoadTest do
  @shortdoc "Runs a local Arblarg federation benchmark and writes performance artifacts"
  @moduledoc """
  Runs a synthetic load test against `Elektrine.Messaging.Federation.receive_event/2`.

  The benchmark now measures the signed Arblarg hot path, including:
  - throughput
  - p50/p95/p99 latency
  - gap rate
  - bytes per event for single-event JSON/CBOR
  - bytes per event for batched JSON/CBOR

  Example:

      mix messaging.federation.load_test --events 5000 --event-type message.create --batch-size 32
  """

  use Mix.Task

  import Ecto.Query, warn: false

  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Messaging.{ChatMessage, Server}
  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.FederationEvent
  alias Elektrine.Messaging.FederationStreamPosition
  alias Elektrine.Repo
  alias Elektrine.Social.Conversation

  @switches [
    events: :integer,
    gap_every: :integer,
    domain: :string,
    event_type: :string,
    batch_size: :integer,
    message_size: :integer,
    report: :string
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)
    previous = Application.get_env(:elektrine, :messaging_federation, [])

    events = max(Keyword.get(opts, :events, 3_000), 10)
    gap_every = max(Keyword.get(opts, :gap_every, 0), 0)
    batch_size = max(Keyword.get(opts, :batch_size, 32), 1)
    message_size = max(Keyword.get(opts, :message_size, 160), 1)
    domain = Keyword.get(opts, :domain, "load.remote")
    event_type = normalize_event_type(Keyword.get(opts, :event_type, "message.create"))
    report_path = Keyword.get(opts, :report, "external/arblarg/benchmarks/latest.json")
    remote_secret = "load-secret:#{domain}"
    run_id = Integer.to_string(System.system_time(:millisecond))

    Application.put_env(
      :elektrine,
      :messaging_federation,
      Keyword.merge(previous,
        enabled: true,
        peers: [
          %{
            "domain" => domain,
            "base_url" => "https://#{domain}",
            "shared_secret" => remote_secret,
            "allow_incoming" => true,
            "allow_outgoing" => false
          }
        ]
      )
    )

    try do
      scenario = build_scenario(domain, event_type, run_id, message_size)
      cleanup(domain, scenario)
      remote_key_id = inbound_key_id_for(domain)

      {duration_us, state} =
        :timer.tc(fn ->
          Enum.reduce(1..events, init_state(), fn i, state ->
            state =
              if gap_every > 0 and rem(i, gap_every) == 0 do
                run_one_event(
                  state,
                  scenario,
                  state.sequence + 1,
                  "gap-#{i}",
                  remote_key_id,
                  remote_secret
                )
              else
                state
              end

            run_one_event(
              state,
              scenario,
              state.sequence,
              "ok-#{i}",
              remote_key_id,
              remote_secret
            )
          end)
        end)

      report =
        benchmark_report(
          state,
          duration_us,
          scenario,
          events,
          batch_size,
          remote_key_id,
          remote_secret
        )

      write_report(report_path, report)
      print_report(report)
    after
      Application.put_env(:elektrine, :messaging_federation, previous)
    end
  end

  defp init_state do
    %{
      sequence: 1,
      calls: 0,
      applied: 0,
      gaps: 0,
      failures: 0,
      latencies_us: [],
      failure_reasons: %{}
    }
  end

  defp run_one_event(state, scenario, sequence, label, remote_key_id, remote_secret) do
    payload = event_payload(scenario, sequence, label, remote_key_id, remote_secret)
    started_us = System.monotonic_time(:microsecond)
    result = Federation.receive_event(payload, scenario.domain)
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

      {:error, reason} ->
        %{
          base
          | failures: base.failures + 1,
            failure_reasons: Map.update(base.failure_reasons, inspect(reason), 1, &(&1 + 1))
        }

      other ->
        %{
          base
          | failures: base.failures + 1,
            failure_reasons: Map.update(base.failure_reasons, inspect(other), 1, &(&1 + 1))
        }
    end
  end

  defp benchmark_report(
         state,
         duration_us,
         scenario,
         requested_events,
         batch_size,
         remote_key_id,
         remote_secret
       ) do
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
    wire_sizes = wire_sizes(scenario, batch_size, remote_key_id, remote_secret)

    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      event_type: scenario.event_type,
      origin_domain: scenario.domain,
      requested_events: requested_events,
      calls: total_calls,
      applied: applied_calls,
      gaps: gaps,
      failures: failures,
      duration_s: Float.round(total_seconds, 3),
      calls_per_s: Float.round(calls_per_second, 2),
      applied_per_s: Float.round(applied_per_second, 2),
      p50_ms: Float.round(p50_ms, 3),
      p95_ms: Float.round(p95_ms, 3),
      p99_ms: Float.round(p99_ms, 3),
      gap_rate_pct: Float.round(gap_rate, 2),
      failure_reasons: state.failure_reasons,
      wire_sizes: wire_sizes
    }
  end

  defp print_report(report) do
    IO.puts("Messaging Federation Load Test")
    IO.puts("================================")
    IO.puts("event_type: #{report.event_type}")
    IO.puts("calls: #{report.calls}")
    IO.puts("applied: #{report.applied}")
    IO.puts("gaps: #{report.gaps}")
    IO.puts("failures: #{report.failures}")
    IO.puts("duration_s: #{report.duration_s}")
    IO.puts("calls_per_s: #{report.calls_per_s}")
    IO.puts("applied_per_s: #{report.applied_per_s}")
    IO.puts("p50_ms: #{report.p50_ms}")
    IO.puts("p95_ms: #{report.p95_ms}")
    IO.puts("p99_ms: #{report.p99_ms}")
    IO.puts("gap_rate_pct: #{report.gap_rate_pct}")
    IO.puts("failure_reasons: #{inspect(report.failure_reasons)}")
    IO.puts("single_json_bytes: #{report.wire_sizes.single_json_bytes}")
    IO.puts("single_cbor_bytes: #{report.wire_sizes.single_cbor_bytes}")
    IO.puts("batch_json_bytes_per_event: #{report.wire_sizes.batch_json_bytes_per_event}")
    IO.puts("batch_cbor_bytes_per_event: #{report.wire_sizes.batch_cbor_bytes_per_event}")
  end

  defp write_report(path, payload) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode_to_iodata!(payload, pretty: true))
  end

  defp wire_sizes(scenario, batch_size, remote_key_id, remote_secret) do
    sample_event = event_payload(scenario, 1, "sample", remote_key_id, remote_secret)

    sample_batch =
      %{
        "version" => 1,
        "batch_id" => "batch-sample",
        "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "events" =>
          Enum.map(1..batch_size, fn index ->
            event_payload(scenario, index, "batch-#{index}", remote_key_id, remote_secret)
          end)
      }

    single_json_bytes = byte_size(Jason.encode!(sample_event))
    single_cbor_bytes = byte_size(CBOR.encode(sample_event))
    batch_json_bytes = byte_size(Jason.encode!(sample_batch))
    batch_cbor_bytes = byte_size(CBOR.encode(sample_batch))

    %{
      single_json_bytes: single_json_bytes,
      single_cbor_bytes: single_cbor_bytes,
      batch_json_bytes: batch_json_bytes,
      batch_cbor_bytes: batch_cbor_bytes,
      batch_json_bytes_per_event: Float.round(batch_json_bytes / batch_size, 2),
      batch_cbor_bytes_per_event: Float.round(batch_cbor_bytes / batch_size, 2)
    }
  end

  defp event_payload(scenario, sequence, label, remote_key_id, remote_secret) do
    payload =
      case scenario.event_type do
        "server.upsert" ->
          %{
            "server" => %{
              "id" => scenario.server_id,
              "name" => "load-#{label}",
              "description" => "federation load test",
              "is_public" => true,
              "member_count" => sequence
            },
            "channels" => []
          }

        "message.create" ->
          %{
            "server" => %{
              "id" => scenario.server_id,
              "name" => "load-channel",
              "is_public" => true
            },
            "channel" => %{
              "id" => scenario.channel_id,
              "name" => "general",
              "position" => 0
            },
            "message" => %{
              "id" => "#{scenario.message_prefix}-#{sequence}",
              "channel_id" => scenario.channel_id,
              "content" => scenario.message_content,
              "message_type" => "text",
              "media_urls" => [],
              "media_metadata" => %{},
              "sender" => %{
                "uri" => "https://#{scenario.domain}/users/loadbot",
                "username" => "loadbot",
                "domain" => scenario.domain,
                "handle" => "loadbot@#{scenario.domain}"
              }
            }
          }
      end

    %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_label" => ArblargSDK.protocol_label(),
      "protocol_version" => ArblargSDK.protocol_version(),
      "event_id" => "load-#{label}-#{Ecto.UUID.generate()}",
      "event_type" => scenario.event_type,
      "origin_domain" => scenario.domain,
      "stream_id" => scenario.stream_id,
      "sequence" => sequence,
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "idempotency_key" => "idem-#{label}-#{sequence}",
      "payload" => payload
    }
    |> ArblargSDK.sign_event_envelope(remote_key_id, remote_secret)
  end

  defp inbound_key_id_for(domain) when is_binary(domain) do
    case Federation.incoming_peer(domain) do
      %{keys: [%{id: id} | _]} when is_binary(id) -> id
      _ -> "k1"
    end
  end

  defp build_scenario(domain, "server.upsert", run_id, _message_size) do
    server_id = "https://#{domain}/_arblarg/servers/load-#{run_id}"

    %{
      domain: domain,
      event_type: "server.upsert",
      stream_id: "server:" <> server_id,
      server_id: server_id
    }
  end

  defp build_scenario(domain, "message.create", run_id, message_size) do
    server_id = "https://#{domain}/_arblarg/servers/load-#{run_id}"
    channel_id = "https://#{domain}/_arblarg/channels/load-#{run_id}"

    %{
      domain: domain,
      event_type: "message.create",
      stream_id: "channel:" <> channel_id,
      server_id: server_id,
      channel_id: channel_id,
      message_prefix: "https://#{domain}/_arblarg/messages/load-#{run_id}",
      message_content: String.duplicate("x", message_size)
    }
  end

  defp cleanup(domain, scenario) do
    Repo.delete_all(from(p in FederationStreamPosition, where: p.origin_domain == ^domain))
    Repo.delete_all(from(e in FederationEvent, where: e.origin_domain == ^domain))
    Repo.delete_all(from(m in ChatMessage, where: m.origin_domain == ^domain))

    Repo.delete_all(
      from(c in Conversation,
        where: c.federated_source == ^Map.get(scenario, :channel_id, "__no_channel__")
      )
    )

    Repo.delete_all(from(s in Server, where: s.federation_id == ^scenario.server_id))
  end

  defp normalize_event_type("server.upsert"), do: "server.upsert"
  defp normalize_event_type(_), do: "message.create"

  defp percentile_ms([], _), do: 0.0

  defp percentile_ms(latencies_us, percentile) do
    sorted = Enum.sort(latencies_us)
    index = max(trunc(Float.ceil(length(sorted) * percentile / 100.0)) - 1, 0)
    sorted |> Enum.at(index, 0) |> Kernel./(1_000)
  end
end
