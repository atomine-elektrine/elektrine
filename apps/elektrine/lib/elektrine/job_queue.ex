defmodule Elektrine.JobQueue do
  @moduledoc false

  alias Oban.{Config, Engine}

  def insert(changeset, opts \\ []) do
    insert_to(Oban, changeset, opts)
  end

  def insert_to(name, changeset, opts \\ []) do
    if running?(name) do
      Oban.insert(name, changeset, opts)
    else
      name
      |> fallback_config()
      |> Engine.insert_job(changeset, opts)
    end
  end

  def insert_all(changesets, opts \\ []) do
    insert_all_to(Oban, changesets, opts)
  end

  def insert_all_to(name, changesets, opts \\ []) do
    if running?(name) do
      Oban.insert_all(name, changesets, opts)
    else
      name
      |> fallback_config()
      |> Engine.insert_all_jobs(changesets, opts)
    end
  end

  def running?(name \\ Oban) do
    not is_nil(Oban.whereis(name))
  end

  defp fallback_config(name) do
    Application.fetch_env!(:elektrine, Oban)
    |> Keyword.merge(
      name: name,
      insert_trigger: false,
      peer: false,
      plugins: [],
      queues: [],
      stage_interval: :infinity
    )
    |> Config.new()
  end
end
