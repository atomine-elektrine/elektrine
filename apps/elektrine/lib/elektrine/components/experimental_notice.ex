defmodule Elektrine.Components.ExperimentalNotice do
  @moduledoc false

  use Phoenix.Component

  @doc "Renders a compact notice for experimental product surfaces."
  attr :title, :string, default: "Experimental"

  attr :message, :string,
    default:
      "This area is still being tested. Behavior may change, and you should not rely on it as your only copy of important information."

  attr :class, :any, default: nil
  attr :rest, :global

  def experimental_notice(assigns) do
    ~H"""
    <div
      class={[
        "alert alert-warning border border-warning/40 shadow-sm",
        @class
      ]}
      role="note"
      {@rest}
    >
      <svg
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="1.5"
        stroke="currentColor"
        class="h-5 w-5 shrink-0"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M12 9v3.75m9-.75a9 9 0 1 1-18 0 9 9 0 0 1 18 0Zm-9 3.75h.008v.008H12v-.008Z"
        />
      </svg>
      <div>
        <p class="font-semibold">{@title}</p>
        <p class="text-xs leading-relaxed opacity-80">{@message}</p>
      </div>
    </div>
    """
  end
end
