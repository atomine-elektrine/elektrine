defmodule Mix.Tasks.Elektrine.Db.RepairIndexes do
  @moduledoc """
  Repairs PostgreSQL indexes with REINDEX.

  Usage:

      mix elektrine.db.repair_indexes
      mix elektrine.db.repair_indexes --index activitypub_actors_domain_index
      mix elektrine.db.repair_indexes --table activitypub_actors
      mix elektrine.db.repair_indexes --no-concurrently
  """

  use Mix.Task

  @shortdoc "Repairs PostgreSQL indexes"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [index: :string, table: :string, concurrently: :boolean],
        aliases: [i: :index, t: :table]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{inspect(invalid)}")
    end

    concurrently? = Keyword.get(opts, :concurrently, true)

    result =
      cond do
        index = Keyword.get(opts, :index) ->
          Elektrine.Database.IndexRepair.reindex_index(index, concurrently: concurrently?)

        table = Keyword.get(opts, :table) ->
          Elektrine.Database.IndexRepair.reindex_table(table, concurrently: concurrently?)

        true ->
          Elektrine.Database.IndexRepair.reindex_database(concurrently: concurrently?)
      end

    case result do
      {:ok, %{command: command}} ->
        Mix.shell().info("Index repair complete: #{command}")

      {:error, %{command: command, reason: reason}} ->
        Mix.raise("Index repair failed for #{command}: #{inspect(reason)}")
    end
  end
end
