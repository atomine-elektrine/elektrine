defmodule Mix.Tasks.Messaging.Federation.InteropSmoke do
  @shortdoc "Runs a local Arblarg interop smoke test against the reference peer"
  @moduledoc """
  Runs a local Arblarg interoperability smoke test between the main federation
  implementation and the in-memory reference peer.

  Example:

      mix messaging.federation.interop_smoke --report external/arblarg/interop/smoke.json
  """

  use Mix.Task

  alias Elektrine.Messaging.ArblargSDK
  alias Elektrine.Messaging.Federation
  alias Elektrine.Messaging.Federation.Config
  alias Elektrine.Messaging.ReferencePeer

  @switches [
    domain: :string,
    secret: :string,
    report: :string
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @switches)
    domain = Keyword.get(opts, :domain, "reference.test")
    secret = Keyword.get(opts, :secret, "reference-secret")
    report_path = Keyword.get(opts, :report, "external/arblarg/interop/smoke.json")

    peer = ReferencePeer.new(domain: domain, secret: secret)
    previous = Application.get_env(:elektrine, :messaging_federation, [])

    Application.put_env(
      :elektrine,
      :messaging_federation,
      Keyword.merge(previous,
        enabled: true,
        peers: [],
        discovery_fetcher: fn
          ^domain, _urls -> {:ok, ReferencePeer.discovery_document(peer)}
          _other, _urls -> {:error, :not_found}
        end
      )
    )

    try do
      {local_to_reference_status, updated_reference_peer} = run_local_to_reference(peer)
      reference_to_local = run_reference_to_local(peer)

      report = %{
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        local_domain: Federation.local_domain(),
        reference_domain: domain,
        local_to_reference: local_to_reference_status,
        reference_to_local: reference_to_local,
        reference_summary: ReferencePeer.summary(updated_reference_peer)
      }

      write_report(report_path, report)
      print_report(report)
    after
      Application.put_env(:elektrine, :messaging_federation, previous)
    end
  end

  defp run_local_to_reference(peer) do
    local_identity = Federation.local_discovery_document()["identity"]

    event =
      signed_local_event(
        "message.create",
        "channel:https://#{Federation.local_domain()}/federation/messaging/channels/interop-local-task",
        1,
        message_payload(Federation.local_domain(), "interop-local-task", "hello from local task")
      )

    case ReferencePeer.receive_event(
           peer,
           event,
           ReferencePeer.key_lookup_from_identity(local_identity)
         ) do
      {:ok, updated_peer, status} -> {status, updated_peer}
      {:error, reason} -> Mix.raise("reference peer rejected local event: #{inspect(reason)}")
    end
  end

  defp run_reference_to_local(peer) do
    case Federation.discover_peer(peer.domain, force: true) do
      {:ok, _peer} -> :ok
      {:error, reason} -> Mix.raise("failed to discover reference peer: #{inspect(reason)}")
    end

    event =
      ReferencePeer.signed_event(
        peer,
        "message.create",
        "channel:https://#{peer.domain}/federation/messaging/channels/interop-ref-task",
        1,
        message_payload(peer.domain, "interop-ref-task", "hello from reference task")
      )

    case Federation.receive_event(event, peer.domain) do
      {:ok, status} ->
        status

      {:error, reason} ->
        Mix.raise("federation rejected reference peer event: #{inspect(reason)}")
    end
  end

  defp signed_local_event(event_type, stream_id, sequence, payload) do
    {key_id, private_key} = local_signing_material()

    %{
      "protocol" => ArblargSDK.protocol_name(),
      "protocol_id" => ArblargSDK.protocol_id(),
      "protocol_label" => ArblargSDK.protocol_label(),
      "protocol_version" => ArblargSDK.protocol_version(),
      "event_id" => "evt-#{Ecto.UUID.generate()}",
      "event_type" => event_type,
      "origin_domain" => Federation.local_domain(),
      "stream_id" => stream_id,
      "sequence" => sequence,
      "sent_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "idempotency_key" => "idem-#{Ecto.UUID.generate()}",
      "payload" => payload
    }
    |> ArblargSDK.sign_event_envelope(key_id, private_key)
  end

  defp local_signing_material do
    config = Application.get_env(:elektrine, :messaging_federation, [])
    key_id = Config.local_identity_key_id(config)

    [key | _] =
      Config.local_identity_keys(
        config,
        key_id,
        Federation.local_domain(),
        true,
        false
      )

    {key.id, key.private_key}
  end

  defp message_payload(domain, suffix, content) do
    %{
      "server" => %{
        "id" => "https://#{domain}/federation/messaging/servers/#{suffix}",
        "name" => "interop-#{suffix}",
        "is_public" => true
      },
      "channel" => %{
        "id" => "https://#{domain}/federation/messaging/channels/#{suffix}",
        "name" => "general",
        "position" => 0
      },
      "message" => %{
        "id" => "https://#{domain}/federation/messaging/messages/#{suffix}",
        "channel_id" => "https://#{domain}/federation/messaging/channels/#{suffix}",
        "content" => content,
        "message_type" => "text",
        "media_urls" => [],
        "media_metadata" => %{},
        "sender" => %{
          "uri" => "https://#{domain}/users/alice",
          "username" => "alice",
          "domain" => domain,
          "handle" => "alice@#{domain}"
        }
      }
    }
  end

  defp write_report(path, payload) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode_to_iodata!(payload, pretty: true))
  end

  defp print_report(report) do
    Mix.shell().info("Arblarg interop smoke test passed")
    Mix.shell().info("  local -> reference: #{report.local_to_reference}")
    Mix.shell().info("  reference -> local: #{report.reference_to_local}")
  end
end
