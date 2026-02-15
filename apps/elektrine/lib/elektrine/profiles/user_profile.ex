defmodule Elektrine.Profiles.UserProfile do
  @moduledoc """
  Schema for customizable user profiles with extensive theming and display options.
  Manages profile appearance, links, widgets, Discord integration, music embeds, and visual effects.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Elektrine.Markdown

  schema "user_profiles" do
    field :display_name, :string
    field :description, :string
    field :location, :string
    field :page_title, :string
    field :favicon_url, :string
    field :theme, :string, default: "blue"
    field :accent_color, :string, default: "#22d3ee"
    field :text_color, :string, default: "#ffffff"
    field :background_color, :string, default: "#1e293b"
    field :icon_color, :string, default: "#22d3ee"
    field :profile_opacity, :float, default: 1.0
    field :profile_blur, :integer, default: 0
    field :container_background_color, :string
    field :container_opacity, :float, default: 0.4
    field :container_pattern, :string, default: "none"
    field :pattern_color, :string
    field :pattern_opacity, :float, default: 0.2
    field :pattern_animated, :boolean, default: false
    field :pattern_animation_speed, :string, default: "normal"
    field :font_family, :string
    field :cursor_style, :string, default: "default"
    field :monochrome_icons, :boolean, default: false
    field :volume_control, :boolean, default: false
    field :use_discord_avatar, :boolean, default: false
    field :avatar_url, :string
    field :avatar_size, :integer, default: 0
    field :avatar_effect, :string, default: "none"
    field :banner_url, :string
    field :banner_size, :integer, default: 0
    field :background_url, :string
    field :background_size, :integer, default: 0
    field :background_type, :string, default: "gradient"
    field :music_url, :string
    field :music_title, :string
    field :discord_user_id, :string
    field :show_discord_presence, :boolean, default: false
    field :is_public, :boolean, default: true
    field :hide_view_counter, :boolean, default: false
    field :hide_uid, :boolean, default: false
    field :hide_followers, :boolean, default: false
    field :hide_avatar, :boolean, default: false
    field :hide_timeline, :boolean, default: false
    field :hide_community_posts, :boolean, default: false
    field :hide_share_button, :boolean, default: false
    field :text_background, :boolean, default: false
    field :page_views, :integer, default: 0

    # Username text effects
    field :username_effect, :string, default: "none"
    field :username_glow_color, :string, default: "#22d3ee"
    field :username_glow_intensity, :integer, default: 10
    field :username_shadow_color, :string, default: "#1e293b"
    field :username_gradient_from, :string
    field :username_gradient_to, :string
    field :username_animation_speed, :string, default: "normal"

    # Verified badge color
    field :tick_color, :string, default: "#22d3ee"

    # Typewriter effect
    field :typewriter_effect, :boolean, default: false
    field :typewriter_speed, :string, default: "normal"
    field :typewriter_title, :boolean, default: false

    # Link display style
    field :link_display_style, :string, default: "circular"
    field :link_highlight_effect, :string, default: "none"

    # Layout options
    field :extend_layout, :boolean, default: true

    # Profile mode: "builder" = drag & drop builder, "static" = custom uploaded files
    field :profile_mode, :string, default: "builder"
    field :static_site_index, :string

    belongs_to :user, Elektrine.Accounts.User

    has_many :links, Elektrine.Profiles.ProfileLink,
      foreign_key: :profile_id,
      preload_order: [asc: :position]

    has_many :widgets, Elektrine.Profiles.ProfileWidget,
      foreign_key: :profile_id,
      preload_order: [asc: :position]

    timestamps()
  end

  @doc false
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [
      :user_id,
      :display_name,
      :description,
      :location,
      :page_title,
      :favicon_url,
      :theme,
      :accent_color,
      :text_color,
      :background_color,
      :icon_color,
      :profile_opacity,
      :profile_blur,
      :container_background_color,
      :container_opacity,
      :container_pattern,
      :pattern_color,
      :pattern_opacity,
      :pattern_animated,
      :pattern_animation_speed,
      :font_family,
      :cursor_style,
      :avatar_url,
      :avatar_size,
      :avatar_effect,
      :banner_url,
      :banner_size,
      :background_url,
      :background_size,
      :background_type,
      :music_url,
      :music_title,
      :discord_user_id,
      :show_discord_presence,
      :hide_view_counter,
      :hide_uid,
      :hide_followers,
      :hide_avatar,
      :hide_timeline,
      :hide_community_posts,
      :hide_share_button,
      :text_background,
      :monochrome_icons,
      :volume_control,
      :use_discord_avatar,
      :username_effect,
      :username_glow_color,
      :username_glow_intensity,
      :username_shadow_color,
      :username_gradient_from,
      :username_gradient_to,
      :username_animation_speed,
      :tick_color,
      :typewriter_effect,
      :typewriter_speed,
      :typewriter_title,
      :link_display_style,
      :link_highlight_effect,
      :extend_layout,
      :profile_mode,
      :static_site_index,
      :is_public
    ])
    |> validate_required([:user_id])
    |> validate_length(:display_name, max: 50)
    |> validate_length(:description, max: 1000)
    |> validate_length(:location, max: 100)
    |> validate_length(:page_title, max: 100)
    |> validate_inclusion(:theme, [
      "purple",
      "blue",
      "green",
      "orange",
      "red",
      "pink",
      "dark",
      "light"
    ])
    |> validate_inclusion(:background_type, ["gradient", "solid", "image", "video"])
    |> validate_inclusion(
      :font_family,
      [
        nil,
        "Inter",
        "Arial",
        "Helvetica",
        "Georgia",
        "Times New Roman",
        "Courier New",
        "Verdana",
        "Trebuchet MS",
        "Comic Sans MS",
        "Impact",
        "Palatino",
        "Garamond",
        "Bookman",
        "Consolas",
        "Monaco"
      ],
      allow_nil: true
    )
    |> validate_inclusion(:cursor_style, [
      "default",
      "pointer",
      "crosshair",
      "help",
      "wait",
      "grab",
      "text",
      "move",
      "not-allowed",
      "cell",
      "context-menu",
      "vertical-text",
      "alias",
      "copy",
      "no-drop"
    ])
    |> validate_format(:accent_color, ~r/^#[0-9a-fA-F]{6}$/, message: "must be a valid hex color")
    |> validate_format(:text_color, ~r/^#[0-9a-fA-F]{6}$/, message: "must be a valid hex color")
    |> validate_format(:background_color, ~r/^#[0-9a-fA-F]{6}$/,
      message: "must be a valid hex color"
    )
    |> validate_format(:icon_color, ~r/^#[0-9a-fA-F]{6}$/, message: "must be a valid hex color")
    |> validate_format(:container_background_color, ~r/^#[0-9a-fA-F]{6}$/,
      message: "must be a valid hex color",
      allow_nil: true
    )
    |> validate_format(:pattern_color, ~r/^#[0-9a-fA-F]{6}$/,
      message: "must be a valid hex color",
      allow_nil: true
    )
    |> validate_number(:profile_opacity,
      greater_than_or_equal_to: 0.5,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:profile_blur, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:container_opacity,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_number(:pattern_opacity,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 1.0
    )
    |> validate_inclusion(:container_pattern, [
      "none",
      "dots",
      "grid",
      "diagonal_lines",
      "zigzag",
      "waves",
      "crosses",
      "houndstooth"
    ])
    |> validate_inclusion(:pattern_animation_speed, ["slow", "normal", "fast"], allow_nil: true)
    |> validate_inclusion(:avatar_effect, [
      "none",
      "glow",
      "rainbow",
      "fire",
      "ice",
      "sparkle",
      "holographic",
      "gold_frame",
      "pulse",
      "rotate_border"
    ])
    |> validate_inclusion(:username_effect, [
      "none",
      "glow",
      "rainbow",
      "neon",
      "shadow",
      "gradient",
      "glitch",
      "fire",
      "ice",
      "chrome",
      "holographic",
      "outline",
      "double",
      "retro",
      "pixelated"
    ])
    |> validate_format(:username_glow_color, ~r/^#[0-9a-fA-F]{6}$/,
      message: "must be a valid hex color",
      allow_nil: true
    )
    |> validate_number(:username_glow_intensity,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 50
    )
    |> validate_format(:username_shadow_color, ~r/^#[0-9a-fA-F]{6}$/,
      message: "must be a valid hex color",
      allow_nil: true
    )
    |> validate_format(:username_gradient_from, ~r/^#[0-9a-fA-F]{6}$/,
      message: "must be a valid hex color",
      allow_nil: true
    )
    |> validate_format(:username_gradient_to, ~r/^#[0-9a-fA-F]{6}$/,
      message: "must be a valid hex color",
      allow_nil: true
    )
    |> validate_inclusion(:username_animation_speed, ["slow", "normal", "fast"], allow_nil: true)
    |> validate_format(:tick_color, ~r/^#[0-9a-fA-F]{6}$/, message: "must be a valid hex color")
    |> validate_inclusion(:typewriter_speed, ["slow", "normal", "fast"], allow_nil: true)
    |> validate_inclusion(:link_display_style, ["circular", "full_width"])
    |> validate_inclusion(:link_highlight_effect, ["none", "glow", "pulse", "border", "shine"])
    |> validate_inclusion(:profile_mode, ["builder", "static"])
    |> validate_markdown_description()
    |> validate_music_url()
    |> validate_discord_user_id()
    |> validate_safe_urls()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
  end

  # Validate markdown description content
  defp validate_markdown_description(changeset) do
    case get_change(changeset, :description) do
      nil ->
        changeset

      description when is_binary(description) ->
        case Markdown.validate(description) do
          {:ok, _} ->
            changeset

          {:error, message} ->
            add_error(changeset, :description, message)
        end

      _ ->
        changeset
    end
  end

  # Validate music_url to only allow safe embed URLs
  defp validate_music_url(changeset) do
    case get_change(changeset, :music_url) do
      nil ->
        changeset

      "" ->
        changeset

      url when is_binary(url) ->
        # Only allow embed URLs from trusted music platforms
        safe_domains = [
          "open.spotify.com/embed/",
          "youtube.com/embed/",
          "youtube-nocookie.com/embed/",
          "w.soundcloud.com/player/",
          "bandcamp.com/EmbeddedPlayer/",
          "music.apple.com/embed/"
        ]

        is_safe =
          Enum.any?(safe_domains, fn domain ->
            String.contains?(url, domain) && String.starts_with?(url, "https://")
          end)

        if is_safe do
          changeset
        else
          add_error(
            changeset,
            :music_url,
            "must be a valid embed URL from Spotify, YouTube, SoundCloud, Bandcamp, or Apple Music"
          )
        end

      _ ->
        changeset
    end
  end

  # Validate discord_user_id to only allow numeric Discord IDs
  defp validate_discord_user_id(changeset) do
    case get_change(changeset, :discord_user_id) do
      nil ->
        changeset

      "" ->
        changeset

      id when is_binary(id) ->
        # Discord IDs are numeric strings, 17-20 characters
        if String.match?(id, ~r/^[0-9]{17,20}$/) do
          changeset
        else
          add_error(changeset, :discord_user_id, "must be a valid numeric Discord user ID")
        end

      _ ->
        changeset
    end
  end

  # Validate that uploaded file URLs are from our own storage system
  defp validate_safe_urls(changeset) do
    changeset
    |> validate_uploaded_url(:background_url)
    |> validate_uploaded_url(:avatar_url)
    |> validate_uploaded_url(:favicon_url)
  end

  defp validate_uploaded_url(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      "" ->
        changeset

      url when is_binary(url) ->
        # Allow URLs from our storage system or S3/R2
        # Storage keys don't start with http, or they're from our configured domains
        is_safe =
          !String.starts_with?(url, "http") ||
            String.contains?(url, ".r2.cloudflarestorage.com") ||
            String.contains?(url, ".s3.") ||
            String.starts_with?(url, "/uploads/")

        if is_safe do
          changeset
        else
          add_error(changeset, field, "must be from the upload system")
        end

      _ ->
        changeset
    end
  end
end
