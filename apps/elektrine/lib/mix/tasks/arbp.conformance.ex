defmodule Mix.Tasks.Arbp.Conformance do
  use Mix.Task

  alias Elektrine.Messaging.ArblargProfiles

  @shortdoc "Runs ARBP conformance suites and writes badge artifacts"

  @moduledoc """
  Runs ARBP conformance test suites and writes profile + extension badge artifacts.

  This task is intended as an operator and CI hard-gate workflow.
  """

  @core_conformance_test "apps/elektrine_web/test/elektrine_web/controllers/arblarg_conformance_test.exs"
  @extension_conformance_test "apps/elektrine/test/elektrine/messaging/arblarg_extension_conformance_test.exs"
  @badge_dir "external/arblarg/conformance/badges"

  @impl true
  def run(_args) do
    run_test_suite(@core_conformance_test)
    run_test_suite(@extension_conformance_test)

    extension_statuses =
      ArblargProfiles.extension_registry()
      |> Enum.map(fn extension ->
        extension_supported? = extension["events"] != [] and extension["stability"] != "reserved"
        {extension["urn"], extension_supported?}
      end)
      |> Map.new()

    write_profile_badges(extension_statuses)
    write_extension_badges(extension_statuses)
    print_operator_flags()
  end

  defp run_test_suite(path) do
    Mix.shell().info("Running ARBP conformance suite: #{path}")
    Mix.Task.reenable("test")
    Mix.Task.run("test", [path])
  end

  defp write_profile_badges(extension_statuses) do
    ArblargProfiles.profile_badges(core_passed?: true, extension_statuses: extension_statuses)
    |> Enum.each(fn badge ->
      file_name = profile_badge_file_name(badge["id"])

      payload = %{
        profile: badge["id"],
        status: badge["status"],
        suite_version: badge["suite_version"],
        conformance_test_command: badge["conformance_test_command"],
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      write_badge(file_name, payload)
    end)
  end

  defp write_extension_badges(extension_statuses) do
    ArblargProfiles.extension_registry(core_passed?: true, extension_statuses: extension_statuses)
    |> Enum.each(fn extension ->
      conformance = extension["conformance"] || %{}

      payload = %{
        extension: extension["urn"],
        stability: extension["stability"],
        status: conformance["status"],
        suite_version: conformance["suite_version"],
        conformance_test_command: conformance["test_command"],
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      write_badge("extension-#{slugify(extension["urn"])}.json", payload)
    end)
  end

  defp write_badge(file_name, payload) do
    badge_file = Path.join(@badge_dir, file_name)

    badge_file
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(badge_file, Jason.encode_to_iodata!(payload, pretty: true))
    Mix.shell().info("Wrote ARBP badge artifact: #{badge_file}")
  end

  defp print_operator_flags do
    flags =
      ArblargProfiles.extension_registry()
      |> Enum.map(& &1["conformance"])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1["env_flag"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Mix.shell().info("Set these environment flags only after CI validation passes:")

    Enum.each(flags, fn flag ->
      Mix.shell().info("  - #{flag}=true")
    end)
  end

  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp profile_badge_file_name(profile_id) do
    case to_string(profile_id) do
      "arbp-core/1.0" -> "arbp-core-1.0.json"
      "arbp-discord/1.0" -> "arbp-discord-1.0.json"
      other -> "#{slugify(other)}.json"
    end
  end
end
