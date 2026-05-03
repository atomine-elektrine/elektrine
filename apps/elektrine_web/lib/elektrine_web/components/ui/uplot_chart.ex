defmodule ElektrineWeb.Components.UI.UPlotChart do
  @moduledoc """
  LiveView wrapper for uPlot time-series charts.
  """

  use Phoenix.Component

  attr :id, :string, required: true
  attr :data, :list, required: true
  attr :label_key, :atom, default: :date
  attr :value_key, :atom, default: :count
  attr :unit, :string, default: ""
  attr :accent, :string, default: "primary"
  attr :granularity, :string, default: "day"
  attr :empty_message, :string, default: "No data yet."
  attr :aria_label, :string, default: "Time series chart"
  attr :class, :string, default: nil

  def uplot_chart(assigns) do
    chart = build_chart(assigns)

    assigns =
      assigns
      |> assign(:chart, chart)
      |> assign(:chart_json, Jason.encode!(chart.payload))

    ~H"""
    <div class={["analytics-chart w-full", @class]}>
      <%= if @chart.has_data do %>
        <div class="mb-3 flex flex-wrap items-center justify-between gap-4 text-xs text-base-content/55">
          <span>{@chart.total_label} total</span>
          <span :if={@chart.partial_period_note}>{@chart.partial_period_note}</span>
          <span>Peak {@chart.max_label}</span>
        </div>
        <div
          id={@id}
          class="analytics-uplot rounded-xl border border-base-content/10 bg-base-100/70 p-3"
          phx-hook="UPlotChart"
          phx-update="ignore"
          data-chart={@chart_json}
          aria-label={@aria_label}
        >
        </div>
      <% else %>
        <div class="rounded-xl border border-dashed border-base-content/15 px-4 py-8 text-center text-sm text-base-content/55">
          {@empty_message}
        </div>
      <% end %>
    </div>
    """
  end

  defp build_chart(assigns) do
    rows =
      Enum.map(
        assigns.data,
        &normalize_row(&1, assigns.label_key, assigns.value_key, assigns.granularity)
      )

    values = Enum.map(rows, & &1.y)
    max_value = Enum.max([0 | values])
    total = Enum.sum(values)
    has_partial_current_period = Enum.any?(rows, & &1.partial)

    %{
      has_data: max_value > 0,
      total_label: value_label(total, assigns.unit),
      max_label: value_label(max_value, assigns.unit),
      partial_period_note: partial_period_note(has_partial_current_period, assigns.granularity),
      payload: %{
        points: rows,
        unit: assigns.unit,
        accent: assigns.accent,
        granularity: assigns.granularity,
        aria_label: assigns.aria_label
      }
    }
  end

  defp normalize_row(row, label_key, value_key, granularity) do
    x_value = value_for(row, label_key)

    %{
      x: unix_time(x_value),
      label: format_label(x_value),
      y: row |> value_for(value_key) |> numeric_value(),
      partial: current_period?(x_value, granularity)
    }
  end

  defp value_for(row, key) when is_map(row), do: Map.get(row, key) || Map.get(row, to_string(key))
  defp value_for(_, _), do: nil

  defp unix_time(%Date{} = date) do
    date
    |> DateTime.new!(~T[12:00:00], "Etc/UTC")
    |> DateTime.to_unix()
  end

  defp unix_time(%DateTime{} = datetime), do: DateTime.to_unix(datetime)

  defp unix_time(%NaiveDateTime{} = datetime) do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix()
  end

  defp unix_time(value) when is_binary(value) do
    with {:error, _reason} <- DateTime.from_iso8601(value),
         {:ok, date} <- Date.from_iso8601(value) do
      unix_time(date)
    else
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime)
      _ -> 0
    end
  end

  defp unix_time(_), do: 0

  defp numeric_value(value) when is_integer(value), do: value
  defp numeric_value(value) when is_float(value), do: value
  defp numeric_value(%Decimal{} = value), do: Decimal.to_float(value)
  defp numeric_value(_), do: 0

  defp format_label(%Date{} = date), do: Calendar.strftime(date, "%b %d")
  defp format_label(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%H:00")
  defp format_label(%NaiveDateTime{} = datetime), do: Calendar.strftime(datetime, "%H:00")
  defp format_label(value) when is_binary(value), do: value
  defp format_label(value), do: to_string(value || "")

  defp current_period?(%Date{} = date, "day"), do: Date.compare(date, Date.utc_today()) == :eq

  defp current_period?(%DateTime{} = datetime, "hour") do
    datetime
    |> DateTime.truncate(:second)
    |> truncate_to_hour()
    |> DateTime.compare(DateTime.utc_now() |> DateTime.truncate(:second) |> truncate_to_hour())
    |> Kernel.==(:eq)
  end

  defp current_period?(%NaiveDateTime{} = datetime, "hour") do
    datetime
    |> DateTime.from_naive!("Etc/UTC")
    |> current_period?("hour")
  end

  defp current_period?(value, granularity) when is_binary(value) do
    with {:error, _reason} <- DateTime.from_iso8601(value),
         {:ok, date} <- Date.from_iso8601(value) do
      current_period?(date, granularity)
    else
      {:ok, datetime, _offset} -> current_period?(datetime, granularity)
      _ -> false
    end
  end

  defp current_period?(_value, _granularity), do: false

  defp truncate_to_hour(%DateTime{} = datetime),
    do: %{datetime | minute: 0, second: 0, microsecond: {0, 0}}

  defp partial_period_note(true, "hour"), do: "Current hour in progress"
  defp partial_period_note(true, "day"), do: "Current day in progress"
  defp partial_period_note(_has_partial_current_period, _granularity), do: nil

  defp value_label(value, ""), do: format_count(value)
  defp value_label(value, unit), do: "#{format_count(value)} #{unit}"

  defp format_count(value) when is_number(value) and value >= 1_000_000,
    do: "#{format_decimal(value / 1_000_000)}M"

  defp format_count(value) when is_number(value) and value >= 1_000,
    do: "#{format_decimal(value / 1_000)}K"

  defp format_count(value) when is_float(value) do
    rounded = Float.round(value, 1)

    if rounded == Float.round(rounded, 0),
      do: Integer.to_string(trunc(rounded)),
      else: to_string(rounded)
  end

  defp format_count(value) when is_integer(value), do: Integer.to_string(value)
  defp format_count(_), do: "0"

  defp format_decimal(value) do
    rounded = Float.round(value, 1)

    if rounded == Float.round(rounded, 0), do: trunc(rounded), else: rounded
  end
end
