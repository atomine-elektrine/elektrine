defmodule ElektrineWeb.Components.UI.Loading do
  @moduledoc """
  Loading state components including spinners, skeletons, and overlays.

  Provides consistent loading indicators for various use cases throughout
  the application with dark theme support.
  """
  use Phoenix.Component
  import Phoenix.HTML, only: [raw: 1]

  @doc """
  Renders a loading spinner.

  Used to indicate loading states for buttons, sections, or inline content.
  Uses the same SVG spinner as the button component for consistency.

  ## Examples

      <.spinner />

      <.spinner size="sm" />

      <.spinner size="lg" />

      <.spinner class="text-primary" />

      <button class="btn">
        <.spinner size="sm" class="mr-2" />
        Loading...
      </button>
  """
  attr :size, :string, default: "md", values: ["sm", "md", "lg"], doc: "Spinner size"
  attr :variant, :string, default: "ring", values: ["ring", "dots"], doc: "Spinner variant"
  attr :class, :string, default: nil, doc: "Additional CSS classes"
  attr :rest, :global, doc: "Additional HTML attributes"

  def spinner(assigns) do
    ~H"""
    <svg
      class={[spinner_animation(@variant), spinner_size_class(@size), @class]}
      viewBox="0 0 24 24"
      xmlns="http://www.w3.org/2000/svg"
      fill="currentColor"
      aria-hidden="true"
      role="status"
      aria-label="Loading"
      {@rest}
    >
      {raw(spinner_svg(@variant))}
    </svg>
    """
  end

  defp spinner_animation("ring"), do: "animate-spin"
  defp spinner_animation("dots"), do: nil
  defp spinner_animation(_), do: "animate-spin"

  defp spinner_svg("ring") do
    ~s|<path fill="currentColor" d="M20.27,4.74a4.93,4.93,0,0,1,1.52,4.61,5.32,5.32,0,0,1-4.1,4.51,5.12,5.12,0,0,1-5.2-1.5,5.53,5.53,0,0,0,6.13-1.48A5.66,5.66,0,0,0,20.27,4.74ZM12.32,11.53a5.49,5.49,0,0,0-1.47-6.2A5.57,5.57,0,0,0,4.71,3.72,5.17,5.17,0,0,1,9.53,2.2,5.52,5.52,0,0,1,13.9,6.45,5.28,5.28,0,0,1,12.32,11.53ZM19.2,20.29a4.92,4.92,0,0,1-4.72,1.49,5.32,5.32,0,0,1-4.34-4.05A5.2,5.2,0,0,1,11.6,12.5a5.6,5.6,0,0,0,1.51,6.13A5.63,5.63,0,0,0,19.2,20.29ZM3.79,19.38A5.18,5.18,0,0,1,2.32,14a5.3,5.3,0,0,1,4.59-4,5,5,0,0,1,4.58,1.61,5.55,5.55,0,0,0-6.32,1.69A5.46,5.46,0,0,0,3.79,19.38ZM12.23,12a5.11,5.11,0,0,0,3.66-5,5.75,5.75,0,0,0-3.18-6,5,5,0,0,1,4.42,2.3,5.21,5.21,0,0,1,.24,5.92A5.4,5.4,0,0,1,12.23,12ZM11.76,12a5.18,5.18,0,0,0-3.68,5.09,5.58,5.58,0,0,0,3.19,5.79c-1,.35-2.9-.46-4-1.68A5.51,5.51,0,0,1,11.76,12ZM23,12.63a5.07,5.07,0,0,1-2.35,4.52,5.23,5.23,0,0,1-5.91.2,5.24,5.24,0,0,1-2.67-4.77,5.51,5.51,0,0,0,5.45,3.33A5.52,5.52,0,0,0,23,12.63ZM1,11.23a5,5,0,0,1,2.49-4.5,5.23,5.23,0,0,1,5.81-.06,5.3,5.3,0,0,1,2.61,4.74A5.56,5.56,0,0,0,6.56,8.06,5.71,5.71,0,0,0,1,11.23Z"/>|
  end

  defp spinner_svg("dots") do
    ~s|<circle cx="4" cy="12" r="3" fill="currentColor"><animate id="a" attributeName="r" begin="0;b.end-0.25s" dur="0.75s" values="3;.2;3"/></circle><circle cx="12" cy="12" r="3" fill="currentColor"><animate attributeName="r" begin="a.end-0.6s" dur="0.75s" values="3;.2;3"/></circle><circle cx="20" cy="12" r="3" fill="currentColor"><animate id="b" attributeName="r" begin="a.end-0.45s" dur="0.75s" values="3;.2;3"/></circle>|
  end

  defp spinner_svg(_), do: spinner_svg("ring")

  @doc """
  Renders a skeleton loader placeholder.

  Used to show placeholder content while actual content is loading,
  providing a better user experience than spinners for content-heavy areas.

  ## Examples

      <.skeleton type="text" />

      <.skeleton type="text" class="w-3/4" />

      <.skeleton type="avatar" />

      <.skeleton type="card" />

      <.skeleton type="post" />

      <!-- Multiple skeleton lines -->
      <div class="space-y-2">
        <.skeleton type="text" class="w-full" />
        <.skeleton type="text" class="w-5/6" />
        <.skeleton type="text" class="w-4/6" />
      </div>
  """
  attr :type, :string,
    default: "text",
    values: ["text", "avatar", "card", "post", "post-compact", "image", "button"],
    doc: "Skeleton type"

  attr :class, :string, default: nil, doc: "Additional CSS classes"
  attr :rest, :global, doc: "Additional HTML attributes"

  def skeleton(assigns) do
    ~H"""
    <%= case @type do %>
      <% "text" -> %>
        <div class={["skeleton h-4", @class]} {@rest}></div>
      <% "avatar" -> %>
        <div class={["skeleton w-12 h-12 rounded-full", @class]} {@rest}></div>
      <% "card" -> %>
        <div class={["bg-base-200 rounded-lg p-4 space-y-3", @class]} {@rest}>
          <div class="skeleton h-4 w-3/4"></div>
          <div class="skeleton h-4 w-1/2"></div>
          <div class="skeleton h-32 w-full"></div>
        </div>
      <% "post" -> %>
        <div class={["card bg-base-200 border border-base-300", @class]} {@rest}>
          <div class="card-body p-4 space-y-3">
            <!-- Header with avatar -->
            <div class="flex items-center gap-3">
              <div class="skeleton w-10 h-10 rounded-full"></div>
              <div class="flex-1 space-y-2">
                <div class="skeleton h-4 w-32"></div>
                <div class="skeleton h-3 w-24"></div>
              </div>
            </div>
            <!-- Content -->
            <div class="space-y-2">
              <div class="skeleton h-4 w-full"></div>
              <div class="skeleton h-4 w-5/6"></div>
              <div class="skeleton h-4 w-3/4"></div>
            </div>
            <!-- Actions -->
            <div class="flex gap-4 pt-2">
              <div class="skeleton h-6 w-16"></div>
              <div class="skeleton h-6 w-16"></div>
              <div class="skeleton h-6 w-16"></div>
            </div>
          </div>
        </div>
      <% "post-compact" -> %>
        <div class={["flex items-start gap-3 p-3 border-b border-base-300", @class]} {@rest}>
          <div class="skeleton w-8 h-8 rounded-full shrink-0"></div>
          <div class="flex-1 space-y-2">
            <div class="skeleton h-3 w-24"></div>
            <div class="skeleton h-4 w-full"></div>
            <div class="skeleton h-4 w-2/3"></div>
          </div>
        </div>
      <% "image" -> %>
        <div class={["skeleton aspect-video", @class]} {@rest}></div>
      <% "button" -> %>
        <div class={["skeleton h-10 w-24", @class]} {@rest}></div>
      <% _ -> %>
        <div class={["skeleton h-4", @class]} {@rest}></div>
    <% end %>
    """
  end

  @doc """
  Renders multiple skeleton posts for feed loading states.

  ## Examples

      <.skeleton_feed count={3} />

      <.skeleton_feed count={5} type="compact" />
  """
  attr :count, :integer, default: 3, doc: "Number of skeleton posts to show"
  attr :type, :string, default: "full", values: ["full", "compact"], doc: "Post style"
  attr :class, :string, default: nil, doc: "Additional CSS classes"

  def skeleton_feed(assigns) do
    ~H"""
    <div class={["space-y-4", @class]}>
      <%= for _i <- 1..@count do %>
        <%= if @type == "compact" do %>
          <.skeleton type="post-compact" />
        <% else %>
          <.skeleton type="post" />
        <% end %>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders a full-screen loading overlay.

  Used for full-page loading states, typically during navigation or
  major data loading operations.

  ## Examples

      <%= if @loading do %>
        <.loading_overlay />
      <% end %>

      <.loading_overlay message="Loading data..." />

      <.loading_overlay
        message="Processing..."
        show_spinner={false}
      />
  """
  attr :message, :string, default: "Loading...", doc: "Loading message text"
  attr :show_spinner, :boolean, default: true, doc: "Whether to show spinner"
  attr :class, :string, default: nil, doc: "Additional CSS classes"
  attr :rest, :global, doc: "Additional HTML attributes"

  def loading_overlay(assigns) do
    ~H"""
    <div
      class={[
        "fixed inset-0 z-50 flex items-center justify-center",
        "bg-base-100/80 backdrop-blur-sm",
        @class
      ]}
      {@rest}
      role="alert"
      aria-busy="true"
    >
      <div class="text-center">
        <%= if @show_spinner do %>
          <div class="mb-4 flex justify-center">
            <.spinner size="lg" class="text-primary" />
          </div>
        <% end %>
        <p class="text-lg font-semibold text-base-content">
          {@message}
        </p>
      </div>
    </div>
    """
  end

  # Private helper functions

  defp spinner_size_class("sm"), do: "w-4 h-4"
  defp spinner_size_class("md"), do: "w-5 h-5"
  defp spinner_size_class("lg"), do: "w-8 h-8"
  defp spinner_size_class(_), do: "w-5 h-5"
end
