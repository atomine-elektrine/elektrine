defmodule ElektrineWeb.Components.UI.UPlotChartTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ElektrineWeb.Components.UI.UPlotChart

  test "marks the current day as an in-progress point" do
    today = Date.utc_today()

    html =
      render_component(&UPlotChart.uplot_chart/1,
        id: "views-chart",
        data: [
          %{date: Date.add(today, -1), count: 12},
          %{date: today, count: 3}
        ],
        label_key: :date,
        value_key: :count,
        unit: "views",
        granularity: "day"
      )

    assert html =~ "Current day in progress"

    assert [%{"partial" => false}, %{"partial" => true}] = chart_payload(html)["points"]
  end

  defp chart_payload(html) do
    [json] =
      html
      |> Floki.parse_document!()
      |> Floki.find("#views-chart")
      |> Floki.attribute("data-chart")

    json
    |> HtmlEntities.decode()
    |> Jason.decode!()
  end
end
