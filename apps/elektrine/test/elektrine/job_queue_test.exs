defmodule Elektrine.JobQueueTest do
  use ExUnit.Case, async: true

  alias Elektrine.JobQueue

  defmodule TestWorker do
    use Oban.Worker, queue: :default

    @impl Oban.Worker
    def perform(%Oban.Job{}), do: :ok
  end

  @worker_name "Elektrine.JobQueueTest.TestWorker"

  test "uses the default Oban instance when it is running" do
    assert JobQueue.running?()

    assert {:ok, %Oban.Job{worker: worker, state: "completed", args: %{"id" => 1}}} =
             JobQueue.insert(TestWorker.new(%{id: 1}))

    assert worker == @worker_name
  end

  test "falls back to direct inserts when an Oban instance is unavailable" do
    refute JobQueue.running?(:missing_oban)

    assert {:ok, %Oban.Job{worker: worker, state: "completed", args: %{"id" => 2}}} =
             JobQueue.insert_to(:missing_oban, TestWorker.new(%{id: 2}))

    assert worker == @worker_name
  end

  test "falls back to direct bulk inserts when an Oban instance is unavailable" do
    jobs =
      :missing_oban_bulk
      |> JobQueue.insert_all_to(Enum.map([3, 4], &TestWorker.new(%{id: &1})))

    assert Enum.map(jobs, & &1.args["id"]) == [3, 4]
    assert Enum.all?(jobs, &(&1.worker == @worker_name))
    assert Enum.all?(jobs, &(&1.state == "completed"))
  end
end

defmodule Elektrine.JobQueueRuntimeFallbackTest do
  use ExUnit.Case, async: false

  alias Elektrine.JobQueue
  alias Elektrine.JobQueueTest.TestWorker

  @worker_name "Elektrine.JobQueueTest.TestWorker"

  setup do
    on_exit(fn ->
      if is_nil(Oban.whereis(Oban)) do
        assert {:ok, _pid} = Supervisor.restart_child(Elektrine.Supervisor, Oban)
      end
    end)

    :ok
  end

  test "falls back when the default Oban instance is temporarily unavailable" do
    assert JobQueue.running?()
    assert :ok = Supervisor.terminate_child(Elektrine.Supervisor, Oban)
    refute JobQueue.running?()

    assert {:ok, %Oban.Job{worker: worker, state: "completed", args: %{"id" => 5}}} =
             JobQueue.insert(TestWorker.new(%{id: 5}))

    assert worker == @worker_name

    assert {:ok, _pid} = Supervisor.restart_child(Elektrine.Supervisor, Oban)
    assert JobQueue.running?()
  end
end
