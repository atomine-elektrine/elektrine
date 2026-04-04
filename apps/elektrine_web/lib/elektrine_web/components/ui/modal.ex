defmodule ElektrineWeb.Components.UI.Modal do
  @moduledoc """
  Modal component for creating dialog windows and overlays.
  """
  use Phoenix.Component
  use Gettext, backend: ElektrineWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders a modal.

  ## Examples

      <.modal id="confirm-modal">
        This is a modal.
      </.modal>

  JS commands may be passed to the `:on_cancel` to configure
  the closing/cancel event, for example:

      <.modal id="confirm" on_cancel={JS.navigate(~p"/posts")}>
        This is another modal.
      </.modal>

  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="modal modal-open fixed inset-0 z-50 hidden"
    >
      <div
        id={"#{@id}-bg"}
        class="modal-backdrop fixed inset-0 bg-base-content/50 transition-opacity"
        aria-hidden="true"
      />
      <div
        class="fixed inset-0 overflow-y-auto"
        aria-labelledby={"#{@id}-title"}
        aria-describedby={"#{@id}-description"}
        role="dialog"
        aria-modal="true"
        tabindex="0"
      >
        <div class="flex min-h-full items-center justify-center p-4 sm:p-6 lg:py-8">
          <div class="w-full max-w-3xl p-4 sm:p-6 lg:py-8">
            <.focus_wrap
              id={"#{@id}-container"}
              phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
              phx-key="escape"
              phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
              class="modal-box modal-surface relative hidden p-8 sm:p-10 transition"
            >
              <div class="absolute top-4 right-4">
                <button
                  phx-click={JS.exec("data-cancel", to: "##{@id}")}
                  type="button"
                  class="btn btn-ghost btn-sm btn-circle"
                  aria-label={gettext("close")}
                >
                  <.icon name="hero-x-mark-solid" class="h-5 w-5" />
                </button>
              </div>
              <div id={"#{@id}-content"}>
                {render_slot(@inner_block)}
              </div>
            </.focus_wrap>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Renders a class-toggled modal wrapper that works for both LiveView and static pages.
  """
  attr :id, :string, default: nil
  attr :title, :string, default: nil
  attr :open, :boolean, default: false
  attr :data_modal, :string, default: nil
  attr :close_action, :string, required: true
  attr :close_mode, :atom, values: [:phx, :data], default: :phx
  attr :max_width, :string, default: "max-w-md"
  attr :box_class, :string, default: nil
  attr :header_class, :string, default: "flex justify-between items-center mb-6"
  attr :title_class, :string, default: "text-xl font-bold"
  attr :close_button_class, :string, default: nil
  attr :show_close_button, :boolean, default: true
  slot :inner_block, required: true

  def basic_modal(assigns) do
    assigns =
      assign(assigns, :close_attrs, modal_close_attrs(assigns.close_mode, assigns.close_action))

    ~H"""
    <div id={@id} data-modal={@data_modal} class={["modal", @open && "modal-open"]}>
      <div class={[
        "modal-box modal-surface text-base-content",
        @max_width,
        @box_class
      ]}>
        <div :if={@title || @show_close_button} class={@header_class}>
          <h2 :if={@title} class={@title_class}>{@title}</h2>
          <button
            :if={@show_close_button}
            type="button"
            class={["btn btn-ghost btn-sm btn-circle", @close_button_class]}
            aria-label={gettext("close")}
            {@close_attrs}
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        {render_slot(@inner_block)}
      </div>

      <div class="modal-backdrop" {@close_attrs}></div>
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all transform ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all transform ease-in duration-200",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.remove_class("hidden", to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      time: 300,
      transition: {"transition-all transform ease-out duration-300", "opacity-0", "opacity-100"}
    )
    |> show("##{id}-container")
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-content")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-all transform ease-in duration-200", "opacity-100", "opacity-0"}
    )
    |> hide("##{id}-container")
    |> JS.add_class("hidden", to: "##{id}")
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  # Import icon component
  defp icon(assigns) do
    ElektrineWeb.Components.UI.Icon.icon(assigns)
  end

  defp modal_close_attrs(:data, action), do: [{"data-action", action}]
  defp modal_close_attrs(:phx, action), do: [{"phx-click", action}]
end
