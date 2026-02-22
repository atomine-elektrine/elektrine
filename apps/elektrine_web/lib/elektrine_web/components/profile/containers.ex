defmodule ElektrineWeb.Components.Profile.Containers do
  @moduledoc false
  use Phoenix.Component

  @doc """
  Renders SVG pattern overlay for profile containers
  """
  attr :pattern, :string, required: true
  attr :color, :string, default: "#ffffff"
  attr :id, :string, required: true
  attr :animated, :boolean, default: false
  attr :speed, :string, default: "normal"
  attr :opacity, :float, default: 0.2

  def container_pattern(assigns) do
    # Animation durations
    assigns = assign(assigns, :duration, get_animation_duration(assigns.speed))

    ~H"""
    <%= case @pattern do %>
      <% "dots" -> %>
        <svg
          class="absolute inset-0 w-full h-full pointer-events-none"
          style={"opacity: #{@opacity}; z-index: 1;"}
        >
          <defs>
            <pattern id={@id} x="0" y="0" width="20" height="20" patternUnits="userSpaceOnUse">
              <circle cx="10" cy="10" r="2" fill={@color}>
                <%= if @animated do %>
                  <animate attributeName="r" values="2;4;2" dur={@duration} repeatCount="indefinite" />
                <% end %>
              </circle>
            </pattern>
          </defs>
          <rect width="100%" height="100%" fill={"url(##{@id})"} />
        </svg>
      <% "grid" -> %>
        <svg
          class="absolute inset-0 w-full h-full pointer-events-none"
          style={"opacity: #{@opacity}; z-index: 1;"}
        >
          <defs>
            <pattern id={@id} x="0" y="0" width="40" height="40" patternUnits="userSpaceOnUse">
              <path d="M 40 0 L 0 0 0 40" fill="none" stroke={@color} stroke-width="1">
                <%= if @animated do %>
                  <animate
                    attributeName="stroke-width"
                    values="1;2;1"
                    dur={@duration}
                    repeatCount="indefinite"
                  />
                <% end %>
              </path>
            </pattern>
          </defs>
          <rect width="100%" height="100%" fill={"url(##{@id})"} />
        </svg>
      <% "diagonal_lines" -> %>
        <svg
          class="absolute inset-0 w-full h-full pointer-events-none"
          style={"opacity: #{@opacity}; z-index: 1;"}
        >
          <defs>
            <pattern id={@id} x="0" y="0" width="30" height="30" patternUnits="userSpaceOnUse">
              <defs>
                <path id={"#{@id}-shape"} d="M 0 30 L 30 0" stroke={@color} stroke-width="2" />
              </defs>
              <%= if @animated do %>
                <g>
                  <use href={"##{@id}-shape"} x="-30" y="0"></use>
                  <use href={"##{@id}-shape"} x="0" y="0"></use>
                  <animateTransform
                    attributeName="transform"
                    type="translate"
                    values="0 0; 30 0"
                    dur={@duration}
                    repeatCount="indefinite"
                  />
                </g>
              <% else %>
                <path d="M 0 30 L 30 0" stroke={@color} stroke-width="2" />
              <% end %>
            </pattern>
          </defs>
          <rect width="100%" height="100%" fill={"url(##{@id})"} />
        </svg>
      <% "zigzag" -> %>
        <svg
          class="absolute inset-0 w-full h-full pointer-events-none"
          style={"opacity: #{@opacity}; z-index: 1;"}
        >
          <defs>
            <pattern id={@id} x="0" y="0" width="60" height="60" patternUnits="userSpaceOnUse">
              <defs>
                <polygon
                  id={"#{@id}-shape"}
                  points="60 60 30 60 45 45 60 30 60 0 60 0 30 30 0 0 0 30 15 45 30 60 60 60"
                  fill={@color}
                />
              </defs>
              <%= if @animated do %>
                <g>
                  <use href={"##{@id}-shape"} x="0" y="-60"></use>
                  <use href={"##{@id}-shape"} x="0" y="0"></use>
                  <animateTransform
                    attributeName="transform"
                    type="translate"
                    values="0 0; 0 60"
                    dur={@duration}
                    repeatCount="indefinite"
                  />
                </g>
              <% else %>
                <polygon
                  points="60 60 30 60 45 45 60 30 60 0 60 0 30 30 0 0 0 30 15 45 30 60 60 60"
                  fill={@color}
                />
              <% end %>
            </pattern>
          </defs>
          <rect width="100%" height="100%" fill={"url(##{@id})"} />
        </svg>
      <% "waves" -> %>
        <svg
          class="absolute inset-0 w-full h-full pointer-events-none"
          style={"opacity: #{@opacity}; z-index: 1;"}
        >
          <defs>
            <pattern id={@id} x="0" y="0" width="100" height="50" patternUnits="userSpaceOnUse">
              <defs>
                <path
                  id={"#{@id}-shape"}
                  d="M 0 25 Q 25 0, 50 25 T 100 25"
                  fill="none"
                  stroke={@color}
                  stroke-width="3"
                />
              </defs>
              <%= if @animated do %>
                <g>
                  <use href={"##{@id}-shape"} x="-100" y="0"></use>
                  <use href={"##{@id}-shape"} x="0" y="0"></use>
                  <animateTransform
                    attributeName="transform"
                    type="translate"
                    values="0 0; 100 0"
                    dur={@duration}
                    repeatCount="indefinite"
                  />
                </g>
              <% else %>
                <path d="M 0 25 Q 25 0, 50 25 T 100 25" fill="none" stroke={@color} stroke-width="3" />
              <% end %>
            </pattern>
          </defs>
          <rect width="100%" height="100%" fill={"url(##{@id})"} />
        </svg>
      <% "crosses" -> %>
        <svg
          class="absolute inset-0 w-full h-full pointer-events-none"
          style={"opacity: #{@opacity}; z-index: 1;"}
        >
          <defs>
            <pattern id={@id} x="0" y="0" width="30" height="30" patternUnits="userSpaceOnUse">
              <path d="M 15 5 L 15 25 M 5 15 L 25 15" stroke={@color} stroke-width="2">
                <%= if @animated do %>
                  <animateTransform
                    attributeName="transform"
                    type="rotate"
                    values="0 15 15; 360 15 15"
                    dur={@duration}
                    repeatCount="indefinite"
                  />
                <% end %>
              </path>
            </pattern>
          </defs>
          <rect width="100%" height="100%" fill={"url(##{@id})"} />
        </svg>
      <% "houndstooth" -> %>
        <svg
          class="absolute inset-0 w-full h-full pointer-events-none"
          style={"opacity: #{@opacity}; z-index: 1;"}
        >
          <defs>
            <pattern id={@id} x="0" y="0" width="60" height="60" patternUnits="userSpaceOnUse">
              <g>
                <g fill={@color}>
                  <!-- Main square -->
                  <rect x="0" y="0" width="30" height="30" />
                  
    <!-- Corner triangles -->
                  <polygon points="45,30 30,30 30,15" />
                  <polygon points="15,30 30,30 30,45" />
                  <polygon points="30,0 45,0 45,15" />
                  <polygon points="60,15 45,15 45,0" />
                  <polygon points="45,15 60,15 60,30" />
                  <polygon points="15,45 0,45 0,30" />
                  <polygon points="0,45 15,45 15,60" />
                  <polygon points="30,60 15,60 15,45" />

                  <%= if @animated do %>
                    <animateTransform
                      attributeName="transform"
                      type="translate"
                      values="0 0; 60 60"
                      dur={@duration}
                      repeatCount="indefinite"
                    />
                  <% end %>
                </g>
              </g>
            </pattern>
          </defs>
          <rect width="100%" height="100%" fill={"url(##{@id})"} />
        </svg>
      <% _ -> %>
        <!-- No pattern -->
    <% end %>
    """
  end

  defp get_animation_duration("slow"), do: "4s"
  defp get_animation_duration("fast"), do: "1s"
  defp get_animation_duration(_), do: "2s"
end
