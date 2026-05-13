defmodule Elektrine.Email.ExternalDeliveryMetricSnapshot do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Elektrine.Repo

  schema "external_email_metric_snapshots" do
    field :metrics, :map, default: %{}
    field :queue_depth, :integer, default: 0
    field :stuck_count, :integer, default: 0
    field :bounce_rate, :float, default: 0.0
    field :complaint_rate, :float, default: 0.0
    field :captured_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :metrics,
      :queue_depth,
      :stuck_count,
      :bounce_rate,
      :complaint_rate,
      :captured_at
    ])
    |> validate_required([
      :metrics,
      :queue_depth,
      :stuck_count,
      :bounce_rate,
      :complaint_rate,
      :captured_at
    ])
  end

  def create_from_metrics(metrics) when is_map(metrics) do
    attrs = %{
      metrics: stringify(metrics),
      queue_depth: metrics.queue_depth,
      stuck_count: metrics.stuck_count,
      bounce_rate: metrics.bounce_rate,
      complaint_rate: metrics.complaint_rate,
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def recent(limit \\ 50) do
    Repo.all(from s in __MODULE__, order_by: [desc: s.captured_at], limit: ^limit)
  end

  def prune_older_than(cutoff) do
    from(s in __MODULE__, where: s.captured_at < ^cutoff)
    |> Repo.delete_all()
  end

  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify({left, right}), do: [stringify(left), stringify(right)]

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
