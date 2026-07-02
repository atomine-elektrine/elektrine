defmodule Elektrine.Social.TimelinePagination do
  @moduledoc """
  Shared keyset pagination helpers for timeline-style message queries.
  """

  import Ecto.Query, warn: false

  def apply(query, %{before_id: before_id} = pagination) do
    lower_bound = lower_bound(pagination)

    query
    |> maybe_before_id(before_id)
    |> maybe_after_id(lower_bound)
  end

  def order(query, :asc) do
    query
    |> exclude(:order_by)
    |> order_by([m], asc: m.id)
  end

  def order(query, :desc) do
    query
    |> exclude(:order_by)
    |> order_by([m], desc: m.id)
  end

  def requested?(%{before_id: nil, since_id: nil, min_id: nil}), do: false
  def requested?(_), do: true

  def lower_bound(%{since_id: nil, min_id: nil}), do: nil
  def lower_bound(%{since_id: since_id, min_id: nil}), do: since_id
  def lower_bound(%{since_id: nil, min_id: min_id}), do: min_id
  def lower_bound(%{since_id: since_id, min_id: min_id}), do: max(since_id, min_id)

  def opts(opts, default_order \\ :desc) do
    before_id = parse_id(Keyword.get(opts, :before_id) || Keyword.get(opts, :cursor))
    since_id = parse_id(Keyword.get(opts, :since_id))
    min_id = parse_id(Keyword.get(opts, :min_id))
    order = normalize_order(Keyword.get(opts, :order), default_order, min_id)

    %{before_id: before_id, since_id: since_id, min_id: min_id, order: order}
  end

  def parse_id(value) when is_integer(value) and value > 0, do: value

  def parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  def parse_id(_), do: nil

  defp maybe_before_id(query, nil), do: query
  defp maybe_before_id(query, before_id), do: from(m in query, where: m.id < ^before_id)
  defp maybe_after_id(query, nil), do: query
  defp maybe_after_id(query, after_id), do: from(m in query, where: m.id > ^after_id)

  defp normalize_order(:asc, _default_order, _min_id), do: :asc
  defp normalize_order("asc", _default_order, _min_id), do: :asc
  defp normalize_order(:desc, _default_order, _min_id), do: :desc
  defp normalize_order("desc", _default_order, _min_id), do: :desc
  defp normalize_order(_, _default_order, min_id) when is_integer(min_id), do: :asc
  defp normalize_order(_, default_order, _), do: default_order
end
