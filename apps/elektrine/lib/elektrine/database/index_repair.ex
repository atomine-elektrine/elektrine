defmodule Elektrine.Database.IndexRepair do
  @moduledoc """
  Operational helpers for repairing PostgreSQL indexes.

  These functions intentionally live outside migrations because reindexing is
  database maintenance, not a schema change.
  """

  alias Elektrine.Repo

  @doc """
  Rebuilds every index in the current database without blocking writes.
  """
  def reindex_database(opts \\ []) do
    concurrently? = Keyword.get(opts, :concurrently, true)
    database = current_database!()

    execute_reindex(:database, database, concurrently?)
  end

  @doc """
  Rebuilds every index on a table.
  """
  def reindex_table(table, opts \\ []) when is_binary(table) do
    concurrently? = Keyword.get(opts, :concurrently, true)
    execute_reindex(:table, table, concurrently?)
  end

  @doc """
  Rebuilds one index.
  """
  def reindex_index(index, opts \\ []) when is_binary(index) do
    concurrently? = Keyword.get(opts, :concurrently, true)
    execute_reindex(:index, index, concurrently?)
  end

  defp execute_reindex(kind, name, concurrently?) when kind in [:database, :table, :index] do
    sql =
      [
        "REINDEX",
        kind |> Atom.to_string() |> String.upcase(),
        if(concurrently?, do: "CONCURRENTLY", else: nil),
        quote_qualified_identifier(name)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    case Repo.query(sql, [], timeout: :infinity, queue_target: 5_000, queue_interval: 60_000) do
      {:ok, result} -> {:ok, %{command: sql, result: result}}
      {:error, reason} -> {:error, %{command: sql, reason: reason}}
    end
  end

  defp current_database! do
    %{rows: [[database]]} = Repo.query!("SELECT current_database()", [])
    database
  end

  defp quote_qualified_identifier(identifier) do
    identifier
    |> String.split(".")
    |> Enum.map_join(".", &quote_identifier/1)
  end

  defp quote_identifier(identifier) do
    escaped = String.replace(identifier, "\"", "\"\"")
    "\"#{escaped}\""
  end
end
