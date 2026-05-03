import uPlot from "uplot";

const COMPACT_NUMBER = new Intl.NumberFormat(undefined, {
  notation: "compact",
  maximumFractionDigits: 1,
});

const FULL_NUMBER = new Intl.NumberFormat(undefined, {
  maximumFractionDigits: 1,
});

const ACCENTS = {
  primary: { stroke: "#8a7cc2", fill: "rgba(138, 124, 194, 0.16)" },
  secondary: { stroke: "#c7796b", fill: "rgba(199, 121, 107, 0.15)" },
  info: { stroke: "#5f87b8", fill: "rgba(95, 135, 184, 0.15)" },
  success: { stroke: "#34d399", fill: "rgba(52, 211, 153, 0.13)" },
};

function parsePayload(el) {
  try {
    return JSON.parse(el.dataset.chart || "{}");
  } catch (_error) {
    return {};
  }
}

function cssVar(name, fallback) {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return value || fallback;
}

function chartWidth(el) {
  const style = getComputedStyle(el);
  const padding = parseFloat(style.paddingLeft || 0) + parseFloat(style.paddingRight || 0);
  const width = (el.getBoundingClientRect().width || el.clientWidth || 640) - padding;

  return Math.max(Math.floor(width), 320);
}

function formatNumber(value) {
  if (!Number.isFinite(value)) return "0";
  return Math.abs(value) >= 1000 ? COMPACT_NUMBER.format(value) : FULL_NUMBER.format(value);
}

function formatTime(value, granularity) {
  const date = new Date(value * 1000);

  if (granularity === "hour") {
    return date.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
  }

  return date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function periodLabel(granularity) {
  return granularity === "hour" ? "current hour" : "current day";
}

function chartData(points) {
  const rows = Array.isArray(points) ? points : [];

  const normalized = rows
    .map((point) => ({
      x: Number(point.x),
      y: Number(point.y),
      partial: point.partial === true,
    }))
    .filter((point) => Number.isFinite(point.x) && Number.isFinite(point.y))
    .sort((a, b) => a.x - b.x);

  const hasPartial = normalized.some((point) => point.partial);

  if (!hasPartial) {
    return {
      hasPartial,
      data: [
        normalized.map((point) => point.x),
        normalized.map((point) => point.y),
      ],
    };
  }

  const partialValues = new Array(normalized.length).fill(null);

  normalized.forEach((point, index) => {
    if (!point.partial) return;

    partialValues[index] = point.y;

    for (let previousIndex = index - 1; previousIndex >= 0; previousIndex--) {
      if (!normalized[previousIndex].partial) {
        partialValues[previousIndex] = normalized[previousIndex].y;
        break;
      }
    }
  });

  return {
    hasPartial,
    data: [
      normalized.map((point) => point.x),
      normalized.map((point) => (point.partial ? null : point.y)),
      partialValues,
    ],
  };
}

function chartOptions(el, payload, hasPartial) {
  const accent = ACCENTS[payload.accent] || ACCENTS.primary;
  const axisColor = cssVar("--color-base-content", "#e4e7eb");
  const gridColor = "rgba(228, 231, 235, 0.11)";
  const unit = payload.unit || "value";
  const granularity = payload.granularity || "day";
  const series = [
    {
      label: "Time",
      value: (_u, value) => (value == null ? "" : formatTime(value, granularity)),
    },
    {
      label: unit,
      stroke: accent.stroke,
      fill: accent.fill,
      width: 2.5,
      points: { size: 5, width: 2, stroke: accent.stroke, fill: cssVar("--color-base-100", "#101419") },
      value: (_u, value) => (value == null ? "" : `${formatNumber(value)} ${unit}`),
    },
  ];

  if (hasPartial) {
    series.push({
      label: `${unit} (${periodLabel(granularity)})`,
      stroke: accent.stroke,
      width: 2.5,
      dash: [6, 4],
      points: { size: 6, width: 2.5, stroke: accent.stroke, fill: accent.fill },
      value: (_u, value) => (value == null ? "" : `${formatNumber(value)} ${unit}`),
    });
  }

  return {
    width: chartWidth(el),
    height: Number(payload.height) || 260,
    padding: [10, 10, 2, 2],
    cursor: {
      drag: { x: false, y: false },
      points: { size: 6, width: 2 },
    },
    legend: {
      show: true,
      live: true,
    },
    scales: {
      x: { time: true },
      y: {
        range: (_u, _min, max) => [0, Math.max(1, max * 1.16)],
      },
    },
    axes: [
      {
        stroke: axisColor,
        grid: { stroke: gridColor, width: 1 },
        ticks: { stroke: gridColor, width: 1 },
        values: (_u, values) => values.map((value) => formatTime(value, granularity)),
      },
      {
        stroke: axisColor,
        grid: { stroke: gridColor, width: 1 },
        ticks: { stroke: gridColor, width: 1 },
        values: (_u, values) => values.map(formatNumber),
      },
    ],
    series,
  };
}

export const UPlotChart = {
  mounted() {
    this.rawPayload = null;
    this.chart = null;
    this.chartHeight = 260;
    this.resizeFrame = null;
    this.renderChart();

    this.resizeObserver = new ResizeObserver(() => {
      if (this.resizeFrame) cancelAnimationFrame(this.resizeFrame);

      this.resizeFrame = requestAnimationFrame(() => {
        if (this.chart) {
          this.chart.setSize({ width: chartWidth(this.el), height: this.chartHeight });
        }
      });
    });

    this.resizeObserver.observe(this.el);
  },

  updated() {
    this.renderChart();
  },

  destroyed() {
    if (this.resizeFrame) cancelAnimationFrame(this.resizeFrame);
    if (this.resizeObserver) this.resizeObserver.disconnect();
    if (this.chart) this.chart.destroy();
  },

  renderChart() {
    const rawPayload = this.el.dataset.chart || "{}";

    if (rawPayload === this.rawPayload && this.chart) return;

    this.rawPayload = rawPayload;

    if (this.chart) {
      this.chart.destroy();
      this.chart = null;
    }

    this.el.innerHTML = "";

    const payload = parsePayload(this.el);
    const preparedData = chartData(payload.points);
    const data = preparedData.data;

    if (data[0].length === 0) return;

    const options = chartOptions(this.el, payload, preparedData.hasPartial);
    this.chartHeight = options.height;
    this.chart = new uPlot(options, data, this.el);
  },
};
