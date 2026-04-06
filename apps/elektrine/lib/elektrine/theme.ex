defmodule Elektrine.Theme do
  @moduledoc """
  Shared website theme defaults, editable override fields, and CSS variable helpers.
  """

  import Ecto.Changeset

  @hex_color_regex ~r/^#[0-9a-fA-F]{6}$/
  @light_text_color "#ffffff"
  @dark_text_color "#000000"
  @platform_brand_colors %{
    "youtube" => "#ff0000",
    "discord" => "#5865f2",
    "instagram" => "#e4405f",
    "twitter" => "#000000",
    "tiktok" => "#000000",
    "telegram" => "#26a5e4",
    "soundcloud" => "#ff5500",
    "twitch" => "#9146ff",
    "reddit" => "#ff4500",
    "spotify" => "#1db954",
    "pinterest" => "#e60023",
    "linkedin" => "#0a66c2",
    "steam" => "#000000",
    "bitcoin" => "#f7931a",
    "ethereum" => "#627eea",
    "gitlab" => "#fc6d26",
    "facebook" => "#1877f2",
    "whatsapp" => "#25d366",
    "threads" => "#000000",
    "github" => "#000000",
    "paypal" => "#00457c",
    "adobe" => "#ff0000",
    "vk" => "#0077ff",
    "email" => "#ea4335",
    "signal" => "#3a76f0",
    "litecoin" => "#345d9d",
    "snapchat" => "#fffc00"
  }
  @brand_colors %{
    "google_blue" => "#4285f4",
    "google_green" => "#34a853",
    "google_yellow" => "#fbbc05",
    "google_red" => "#ea4335",
    "authy_red" => "#ec1c24",
    "microsoft_red" => "#f25022",
    "microsoft_green" => "#7fba00",
    "microsoft_blue" => "#00a4ef",
    "microsoft_yellow" => "#ffb900"
  }

  @editor_fields [
    %{
      key: "color_primary",
      css_var: "--theme-override-color-primary",
      label: "Primary",
      description: "Main brand color for buttons, focus states, and accents",
      default: "#129fb8"
    },
    %{
      key: "color_secondary",
      css_var: "--theme-override-color-secondary",
      label: "Secondary",
      description: "Secondary accent used in gradients and supporting actions",
      default: "#2c5ce0"
    },
    %{
      key: "color_accent",
      css_var: "--theme-override-color-accent",
      label: "Accent",
      description: "Extra accent color for highlights and decorative UI",
      default: "#3d8fd8"
    },
    %{
      key: "color_base_100",
      css_var: "--theme-override-color-base-100",
      label: "Base 100",
      description: "Main page background",
      default: "#050b16"
    },
    %{
      key: "color_base_200",
      css_var: "--theme-override-color-base-200",
      label: "Base 200",
      description: "Panel and card background",
      default: "#081320"
    },
    %{
      key: "color_base_300",
      css_var: "--theme-override-color-base-300",
      label: "Base 300",
      description: "Borders and elevated surfaces",
      default: "#10243b"
    },
    %{
      key: "color_base_content",
      css_var: "--theme-override-color-base-content",
      label: "Text",
      description: "Primary text and foreground color",
      default: "#e6f7ff"
    },
    %{
      key: "color_info",
      css_var: "--theme-override-color-info",
      label: "Info",
      description: "Informational badges and alerts",
      default: "#3298e2"
    },
    %{
      key: "color_success",
      css_var: "--theme-override-color-success",
      label: "Success",
      description: "Success states and confirmation UI",
      default: "#177b68"
    },
    %{
      key: "color_warning",
      css_var: "--theme-override-color-warning",
      label: "Warning",
      description: "Warnings and caution states",
      default: "#8a652c"
    },
    %{
      key: "color_error",
      css_var: "--theme-override-color-error",
      label: "Error",
      description: "Errors and destructive actions",
      default: "#a94464"
    }
  ]

  @allowed_override_keys MapSet.new(Enum.map(@editor_fields, & &1.key))
  @default_overrides Map.new(@editor_fields, &{&1.key, &1.default})
  @css_var_by_key Map.new(@editor_fields, &{&1.key, &1.css_var})

  def editor_fields, do: @editor_fields

  def default_overrides, do: @default_overrides

  def default_value(key), do: Map.get(@default_overrides, key)

  def inverse_text_color, do: @light_text_color

  def dark_text_color, do: @dark_text_color

  def platform_brand_color(platform) when is_binary(platform) do
    Map.get(@platform_brand_colors, platform, default_value("color_warning"))
  end

  def platform_brand_color(_), do: default_value("color_warning")

  def brand_color(name) when is_binary(name) do
    Map.get(@brand_colors, name, default_value("color_primary"))
  end

  def brand_color(_), do: default_value("color_primary")

  def calendar_default_color, do: default_value("color_primary")

  def community_flair_default_text_color, do: inverse_text_color()

  def community_flair_default_background_color, do: default_value("color_base_300")

  def trust_level_color(level) do
    case level do
      0 -> default_value("color_base_content")
      1 -> default_value("color_info")
      2 -> default_value("color_success")
      3 -> default_value("color_warning")
      4 -> default_value("color_error")
      _ -> default_value("color_base_content")
    end
  end

  def reputation_palette(level) do
    accent = trust_level_color(level)

    %{
      accent: accent,
      surface: mix(accent, inverse_text_color(), 0.9),
      glow: rgba(accent, 0.28)
    }
  end

  def value(overrides, key) when is_map(overrides),
    do: Map.get(overrides, key, default_value(key))

  def value(_, key), do: default_value(key)

  def validate_overrides(changeset, field \\ :theme_overrides) do
    overrides = get_field(changeset, field) || %{}

    cond do
      overrides == %{} ->
        put_change(changeset, field, %{})

      not is_map(overrides) ->
        add_error(changeset, field, "must be a map")

      true ->
        case normalize_overrides(overrides) do
          {:ok, normalized} -> put_change(changeset, field, normalized)
          {:error, message} -> add_error(changeset, field, message)
        end
    end
  end

  def style_attribute(overrides) when is_map(overrides) do
    overrides
    |> Enum.reduce([], fn {key, value}, acc ->
      case Map.fetch(@css_var_by_key, key) do
        {:ok, css_var} when is_binary(value) -> ["#{css_var}: #{value}" | acc]
        _ -> acc
      end
    end)
    |> Kernel.++(derived_content_css_vars(overrides))
    |> Enum.reverse()
    |> Enum.join("; ")
  end

  def style_attribute(_), do: ""

  def effective_overrides(overrides \\ %{}) do
    @default_overrides
    |> Map.merge(configured_default_overrides())
    |> Map.merge(sanitize_overrides(overrides))
  end

  def effective_style_attribute(overrides \\ %{}) do
    overrides
    |> effective_overrides()
    |> style_attribute()
  end

  def meta_theme_color(overrides) do
    value(overrides, "color_base_100")
  end

  def effective_meta_theme_color(overrides \\ %{}) do
    overrides
    |> effective_overrides()
    |> meta_theme_color()
  end

  def hex_to_rgb("#" <> hex) when byte_size(hex) == 6 do
    {red, ""} = Integer.parse(String.slice(hex, 0, 2), 16)
    {green, ""} = Integer.parse(String.slice(hex, 2, 2), 16)
    {blue, ""} = Integer.parse(String.slice(hex, 4, 2), 16)
    {red, green, blue}
  end

  def hex_to_rgb(_), do: default_value("color_primary") |> hex_to_rgb()

  def rgb_to_hex(red, green, blue) do
    red = red |> round() |> max(0) |> min(255)
    green = green |> round() |> max(0) |> min(255)
    blue = blue |> round() |> max(0) |> min(255)

    "#" <>
      String.pad_leading(Integer.to_string(red, 16), 2, "0") <>
      String.pad_leading(Integer.to_string(green, 16), 2, "0") <>
      String.pad_leading(Integer.to_string(blue, 16), 2, "0")
  end

  def mix(first_hex, second_hex, ratio_to_second) do
    {first_red, first_green, first_blue} = hex_to_rgb(first_hex)
    {second_red, second_green, second_blue} = hex_to_rgb(second_hex)
    ratio = ratio_to_second |> max(0.0) |> min(1.0)
    first_ratio = 1.0 - ratio

    rgb_to_hex(
      first_red * first_ratio + second_red * ratio,
      first_green * first_ratio + second_green * ratio,
      first_blue * first_ratio + second_blue * ratio
    )
  end

  def lighten(hex, factor), do: mix(hex, @light_text_color, factor)

  def darken(hex, factor), do: mix(hex, @dark_text_color, factor)

  def rgba(hex, alpha) do
    {red, green, blue} = hex_to_rgb(hex)
    "rgba(#{red}, #{green}, #{blue}, #{alpha})"
  end

  def gradient_pair(hex) do
    {darken(hex, 0.5), darken(hex, 0.35)}
  end

  def contrast_text(hex, opts \\ []) do
    {red, green, blue} = hex_to_rgb(hex)
    threshold = Keyword.get(opts, :threshold, 0.5)
    light = Keyword.get(opts, :light, @light_text_color)
    dark = Keyword.get(opts, :dark, @dark_text_color)
    luminance = 0.2126 * (red / 255) + 0.7152 * (green / 255) + 0.0722 * (blue / 255)

    if luminance > threshold, do: dark, else: light
  end

  def email_palette(source, variant \\ :default) do
    overrides = extract_overrides(source)
    primary = value(overrides, "color_primary")
    success = value(overrides, "color_success")
    warning = value(overrides, "color_warning")
    error = value(overrides, "color_error")
    base_100 = value(overrides, "color_base_100")
    base_200 = value(overrides, "color_base_200")
    base_300 = value(overrides, "color_base_300")
    base_content = value(overrides, "color_base_content")

    accent =
      case variant do
        :warning -> warning
        :error -> error
        :success -> success
        _ -> primary
      end

    %{
      page_bg: darken(base_100, 0.28),
      card_bg: darken(base_100, 0.16),
      card_border: mix(base_300, base_100, 0.28),
      divider: mix(base_300, base_100, 0.28),
      text_heading: accent,
      text_strong: mix(base_content, @light_text_color, 0.08),
      text_body: mix(base_content, base_100, 0.12),
      text_muted: mix(base_content, base_100, 0.34),
      text_subtle: mix(base_content, base_100, 0.52),
      button_bg: primary,
      button_text: contrast_text(primary),
      accent_link: primary,
      notice_text: warning,
      success_text: success,
      alert_bg: mix(accent, base_100, 0.82),
      alert_border: accent,
      alert_text: mix(accent, @light_text_color, 0.45),
      card_subtle_bg: mix(base_200, base_100, 0.22),
      detail_highlight: mix(error, @light_text_color, 0.3)
    }
  end

  def inline_vars(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.map_join("; ", fn {key, value} -> "#{key}: #{value}" end)
  end

  def inline_vars(_), do: ""

  def action_text_color(hex) do
    contrast_text(hex,
      threshold: 0.72,
      light: @light_text_color,
      dark: "#101317"
    )
  end

  defp normalize_overrides(overrides) do
    Enum.reduce_while(overrides, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = to_string(key)
      value = normalize_value(value)

      cond do
        not MapSet.member?(@allowed_override_keys, key) ->
          {:halt, {:error, "contains unsupported theme keys"}}

        value in [nil, ""] ->
          {:cont, {:ok, acc}}

        not Regex.match?(@hex_color_regex, value) ->
          {:halt, {:error, "must use 6-digit hex colors"}}

        true ->
          {:cont, {:ok, Map.put(acc, key, String.downcase(value))}}
      end
    end)
  end

  defp normalize_value(value) when is_binary(value), do: String.trim(value)
  defp normalize_value(value) when is_atom(value), do: value |> Atom.to_string() |> String.trim()
  defp normalize_value(_), do: nil

  defp derived_content_css_vars(overrides) do
    [
      {"color_primary", "--color-primary-content"},
      {"color_secondary", "--color-secondary-content"},
      {"color_accent", "--color-accent-content"},
      {"color_info", "--color-info-content"},
      {"color_success", "--color-success-content"},
      {"color_warning", "--color-warning-content"},
      {"color_error", "--color-error-content"}
    ]
    |> Enum.reduce([], fn {override_key, css_var}, acc ->
      case Map.get(overrides, override_key) do
        value when is_binary(value) and value != "" ->
          ["#{css_var}: #{action_text_color(value)}" | acc]

        _ ->
          acc
      end
    end)
  end

  defp configured_default_overrides do
    :elektrine
    |> Application.get_env(:theme_defaults, %{})
    |> sanitize_overrides()
  end

  defp sanitize_overrides(overrides) when is_map(overrides) do
    case normalize_overrides(overrides) do
      {:ok, normalized} -> normalized
      {:error, _message} -> %{}
    end
  end

  defp sanitize_overrides(_), do: %{}

  defp extract_overrides(%{theme_overrides: overrides}) when is_map(overrides), do: overrides
  defp extract_overrides(overrides) when is_map(overrides), do: overrides
  defp extract_overrides(_), do: %{}
end
