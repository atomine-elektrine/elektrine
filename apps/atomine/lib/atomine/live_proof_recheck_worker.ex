defmodule Atomine.LiveProofRecheckWorker do
  @moduledoc """
  Periodically rechecks due live proofs.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  @default_limit 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    limit = Map.get(args || %{}, "limit", @default_limit)
    _results = Atomine.Personhood.recheck_due_live_proofs(limit)
    :ok
  end
end
