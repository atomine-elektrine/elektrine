defmodule ElektrineWeb.Components.UI.SectionHeader do
  @moduledoc """
  Standard section header with optional eyebrow, description, and actions.
  """

  use Phoenix.Component

  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :string, default: nil
  attr :align, :string, default: "between", values: ["between", "start"]
  slot :actions

  def section_header(assigns) do
    ~H"""
    <div class={[
      "flex flex-col gap-3 sm:gap-4",
      if(@align == "between", do: "sm:flex-row sm:items-start sm:justify-between"),
      @class
    ]}>
      <div class="min-w-0">
        <p
          :if={@eyebrow}
          class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/50"
        >
          {@eyebrow}
        </p>
        <h2 class="mt-1 text-lg font-semibold sm:text-xl">{@title}</h2>
        <p :if={@description} class="mt-1.5 text-sm text-base-content/70 sm:text-base">
          {@description}
        </p>
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end
end
