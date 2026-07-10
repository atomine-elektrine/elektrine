defmodule ElektrineWeb.ProfileLive.DesignThemeSections do
  @moduledoc false

  use ElektrineWeb, :html

  attr :profile, :map, required: true

  def design_colors_card(assigns) do
    ~H"""
    <.card body_class="p-4 sm:p-6">
      <:body>
        <div class="mb-6">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <h2 class="card-title text-lg sm:text-xl mb-2 flex items-center gap-2">
                <.icon name="hero-swatch" class="w-6 h-6" /> Colors
              </h2>

              <p class="text-sm text-base-content/60">Fine-tune each color separately</p>
            </div>
            <.button
              type="button"
              phx-click="reset_design_section"
              phx-value-section="colors"
              variant="ghost"
              size="sm"
            >
              Reset colors
            </.button>
          </div>
        </div>

        <.form for={%{}} phx-submit="update_profile" multipart class="space-y-4 sm:space-y-6">
          <div class="flex items-center gap-4">
            <input
              type="color"
              name="profile[accent_color]"
              value={@profile.accent_color || Elektrine.Profiles.UserProfile.default(:accent_color)}
              phx-change="update_color"
              phx-value-field="accent_color"
              class="w-16 h-16 border-0 rounded-lg cursor-pointer"
            />
            <div>
              <p class="font-medium">Accent Color</p>

              <p class="text-sm text-base-content/70">Links, icons, and highlights</p>
            </div>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <.color_picker
              field="text_color"
              value={@profile.text_color || Elektrine.Profiles.UserProfile.default(:text_color)}
              title="Text Color"
              description="Color for main text"
            />

            <.color_picker
              field="background_color"
              value={
                @profile.background_color ||
                  Elektrine.Profiles.UserProfile.default(:background_color)
              }
              title="Page Background"
              description="Background behind the content box"
            />

            <.color_picker
              field="icon_color"
              value={@profile.icon_color || Elektrine.Profiles.UserProfile.default(:icon_color)}
              title="Icon Color"
              description="Color for social icons"
            />

            <.color_picker
              field="container_background_color"
              value={
                @profile.container_background_color ||
                  Elektrine.Profiles.UserProfile.default(:background_color)
              }
              title="Card background"
              description="Background for the middle content box"
            />

            <.color_picker
              field="tick_color"
              value={@profile.tick_color || Elektrine.Profiles.UserProfile.default(:tick_color)}
              title="Verified Badge Color"
              description="Color for your verified checkmark"
            />
          </div>

          <.design_section_heading
            title="Container"
            description="Card color, pattern, and texture"
            reset_section="container"
            reset_label="Reset container"
          />

          <div>
            <label class="label">
              <span class="label-text font-medium">Container Pattern</span>
            </label>
            <div class="select select-bordered w-full">
              <select name="profile[container_pattern]" phx-change="update_effect">
                <%= for {value, label} <- container_patterns() do %>
                  <option value={value} selected={@profile.container_pattern == value}>
                    {label}
                  </option>
                <% end %>
              </select>
            </div>
          </div>

          <%= if @profile.container_pattern != "none" do %>
            <.color_picker
              field="pattern_color"
              value={@profile.pattern_color || Elektrine.Profiles.UserProfile.default(:text_color)}
              title="Pattern Color"
              description="Color for the pattern overlay"
            />

            <div class="form-control">
              <label class="label cursor-pointer justify-start gap-3">
                <input type="hidden" name="profile[pattern_animated]" value="false" />
                <input
                  type="checkbox"
                  name="profile[pattern_animated]"
                  value="true"
                  checked={@profile.pattern_animated}
                  class="checkbox checkbox-primary"
                />
                <span class="label-text">
                  <span class="font-semibold">Animate Pattern</span>
                  <span class="text-sm text-base-content/70 block">Add motion to your pattern</span>
                </span>
              </label>
            </div>

            <%= if @profile.pattern_animated do %>
              <div>
                <label class="label">
                  <span class="label-text font-medium">Animation Speed</span>
                </label>
                <div class="select select-bordered w-full">
                  <select name="profile[pattern_animation_speed]">
                    <%= for {value, label} <- speed_options() do %>
                      <option
                        value={value}
                        selected={
                          @profile.pattern_animation_speed == value ||
                            (value == "normal" && !@profile.pattern_animation_speed)
                        }
                      >
                        {label}
                      </option>
                    <% end %>
                  </select>
                </div>
              </div>
            <% end %>
          <% end %>

          <.design_section_heading
            title="Background"
            description="Page backdrop and uploaded media"
            reset_section="background"
            reset_label="Reset background"
          />

          <div>
            <label class="label">
              <span class="label-text font-medium">Background Style</span>
            </label>
            <div class="select select-bordered w-full">
              <select name="profile[background_type]" phx-change="update_effect">
                <%= for {value, label} <- background_types() do %>
                  <option value={value} selected={@profile.background_type == value}>
                    {label}
                  </option>
                <% end %>
              </select>
            </div>
          </div>

          <div class="form-control">
            <label class="label cursor-pointer justify-start gap-3">
              <input type="hidden" name="profile[text_background]" value="false" />
              <input
                type="checkbox"
                name="profile[text_background]"
                value="true"
                checked={@profile.text_background}
                class="checkbox checkbox-primary"
              />
              <span class="label-text">
                <span class="font-semibold">Text Background</span>
                <span class="text-sm text-base-content/70 block">
                  Add semi-transparent background behind text for better readability
                </span>
              </span>
            </label>
          </div>

          <.button type="submit" class="w-full">Save Design</.button>
        </.form>
      </:body>
    </.card>
    """
  end

  attr :field, :string, required: true
  attr :value, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true

  defp color_picker(assigns) do
    ~H"""
    <div class="flex items-center gap-4">
      <input
        type="color"
        name={"profile[#{@field}]"}
        value={@value}
        phx-change="update_color"
        phx-value-field={@field}
        class="w-16 h-16 border-0 rounded-lg cursor-pointer"
      />
      <div>
        <p class="font-medium">{@title}</p>
        <p class="text-sm text-base-content/70">{@description}</p>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :reset_section, :string, required: true
  attr :reset_label, :string, required: true

  defp design_section_heading(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 border-t border-base-300 pt-4">
      <div>
        <p class="font-semibold">{@title}</p>
        <p class="text-sm text-base-content/60">{@description}</p>
      </div>
      <.button
        type="button"
        phx-click="reset_design_section"
        phx-value-section={@reset_section}
        variant="ghost"
        size="sm"
      >
        {@reset_label}
      </.button>
    </div>
    """
  end

  defp container_patterns do
    [
      {"none", "None"},
      {"dots", "Dots"},
      {"grid", "Grid"},
      {"diagonal_lines", "Diagonal Lines"},
      {"zigzag", "Zigzag"},
      {"waves", "Waves"},
      {"crosses", "Crosses"},
      {"houndstooth", "Houndstooth"}
    ]
  end

  defp background_types do
    [
      {"gradient", "Gradient"},
      {"solid", "Solid Color"},
      {"image", "Custom Image"},
      {"video", "Video (MP4/WebM)"}
    ]
  end

  defp speed_options do
    [
      {"slow", "Slow"},
      {"normal", "Normal"},
      {"fast", "Fast"}
    ]
  end
end
