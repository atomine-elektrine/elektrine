defmodule Mix.Tasks.Messaging.Arblarg.SyncArtifacts do
  @moduledoc """
  Syncs versioned Arblarg schema artifacts from the live SDK into `external/arblarg`.
  """
  use Mix.Task

  @shortdoc "Syncs published Arblarg schema artifacts from the live SDK"

  alias Elektrine.Messaging.ArblargSDK

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    version = ArblargSDK.protocol_version()
    major_version = version |> String.split(".") |> List.first()

    schema_dir =
      Path.expand("external/arblarg/schemas/v#{major_version}", File.cwd!())

    File.mkdir_p!(schema_dir)

    expected_files =
      ArblargSDK.schema_names(version)
      |> Enum.map(fn schema_name ->
        schema = ArblargSDK.schema(version, schema_name)
        path = Path.join(schema_dir, "#{schema_name}.json")

        encoded_schema =
          schema
          |> Jason.encode_to_iodata!(pretty: true)
          |> IO.iodata_to_binary()

        File.write!(path, encoded_schema <> "\n")
        Path.basename(path)
      end)
      |> MapSet.new()

    schema_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.reject(&MapSet.member?(expected_files, &1))
    |> Enum.each(fn stale_file ->
      File.rm!(Path.join(schema_dir, stale_file))
    end)

    Mix.shell().info("Synced Arblarg schema artifacts in #{schema_dir}")
  end
end
