defmodule Elektrine.Components.User.UsernameEffects do
  @moduledoc false
  use Phoenix.Component

  import Phoenix.HTML, only: [html_escape: 1, raw: 1, safe_to_string: 1]
  alias Elektrine.Profiles.UserProfile

  import Elektrine.Components.TrustLevelBadge
  import Elektrine.Components.User.VerificationBadge

  attr :user, :map, required: true
  attr :display_name, :boolean, default: false
  attr :show_at, :boolean, default: false
  attr :show_verified, :boolean, default: true
  attr :verified_size, :string, default: "sm"
  attr :show_trust_level, :boolean, default: false
  attr :trust_level_size, :string, default: "sm"
  attr :class, :string, default: ""
  attr :rest, :global

  def username_with_effects(assigns) do
    if assigns.user == nil do
      assigns =
        assign(assigns, %{
          username: "unknown",
          effect_class: "",
          animation_class: "",
          inline_styles: "",
          verified_color: UserProfile.default(:tick_color),
          is_verified: false
        })

      ~H"""
      <span class="inline-flex items-center gap-1">
        <span>
          <%= if @show_at do %>
            <span>@</span>
          <% end %>unknown
        </span>
      </span>
      """
    else
      render_username(assigns)
    end
  end

  defp render_username(assigns) do
    {user, profile} =
      cond do
        is_map(assigns.user) && !Map.has_key?(assigns.user, :__struct__) ->
          user =
            case Map.get(assigns.user, :user_id) do
              user_id when is_integer(user_id) ->
                Elektrine.Repo.get(Elektrine.Accounts.User, user_id)
                |> maybe_preload_profile()
                |> Kernel.||(assigns.user)

              _ ->
                assigns.user
            end

          {user, extract_profile(user)}

        Map.has_key?(assigns.user, :__struct__) && Map.has_key?(assigns.user, :profile) ->
          user = maybe_preload_profile(assigns.user)
          {user, extract_profile(user)}

        true ->
          {assigns.user, nil}
      end

    username =
      if assigns.display_name do
        profile_display_name(profile) ||
          Map.get(user, :display_name) ||
          Map.get(user, :handle) ||
          Map.get(user, :username)
      else
        Map.get(user, :handle) || Map.get(user, :username)
      end

    effect_class = get_effect_class(profile)
    animation_class = get_animation_class(profile)
    inline_styles = get_inline_styles(profile)

    verified_color =
      if profile && profile.tick_color do
        profile.tick_color
      else
        UserProfile.default(:tick_color)
      end

    is_verified = Map.get(user, :verified, false)

    rendered_username =
      if assigns.display_name do
        username
        |> html_escape()
        |> safe_to_string()
        |> render_custom_emojis()
      else
        username
      end

    assigns =
      assign(assigns, %{
        username: username,
        rendered_username: rendered_username,
        effect_class: effect_class,
        animation_class: animation_class,
        inline_styles: inline_styles,
        verified_color: verified_color,
        is_verified: is_verified
      })

    ~H"""
    <span class="inline-flex items-center gap-1">
      <span
        class={[@effect_class, @animation_class, @class]}
        style={@inline_styles}
        data-text={
          if @effect_class in ["username-effect-glitch", "username-effect-double"],
            do: if(@show_at, do: "@#{@username}", else: @username),
            else: nil
        }
        {@rest}
      >
        <%= if @show_at do %>
          @
        <% end %>
        <%= if @display_name do %>
          {raw(@rendered_username)}
        <% else %>
          {@rendered_username}
        <% end %>
      </span>
      <%= if @is_verified && @show_verified do %>
        <.verification_badge size={@verified_size} color={@verified_color} tooltip="Verified Account" />
      <% end %>
      <%= if @show_trust_level do %>
        <.trust_level_badge level={Map.get(@user, :trust_level, 0)} size={@trust_level_size} />
      <% end %>
    </span>
    """
  end

  defp maybe_preload_profile(nil), do: nil

  defp maybe_preload_profile(user) do
    if Ecto.assoc_loaded?(user.profile) do
      user
    else
      Elektrine.Repo.preload(user, :profile)
    end
  end

  defp extract_profile(nil), do: nil
  defp extract_profile(user), do: Map.get(user, :profile)

  defp profile_display_name(%{display_name: display_name})
       when is_binary(display_name) and display_name != "",
       do: display_name

  defp profile_display_name(_), do: nil
  defp get_effect_class(nil), do: ""

  defp get_effect_class(profile) do
    case profile.username_effect do
      "glow" -> "username-effect-glow"
      "rainbow" -> "username-effect-rainbow"
      "neon" -> "username-effect-neon"
      "shadow" -> "username-effect-shadow"
      "gradient" -> "username-effect-gradient"
      "glitch" -> "username-effect-glitch"
      "fire" -> "username-effect-fire"
      "ice" -> "username-effect-ice"
      "chrome" -> "username-effect-chrome"
      "holographic" -> "username-effect-holographic"
      "outline" -> "username-effect-outline"
      "double" -> "username-effect-double"
      "retro" -> "username-effect-retro"
      "pixelated" -> "username-effect-pixelated"
      _ -> ""
    end
  end

  defp get_animation_class(nil), do: ""

  defp get_animation_class(profile) do
    animated_effects = ["rainbow", "glitch", "neon", "fire", "ice", "holographic"]

    if profile.username_effect in animated_effects do
      case profile.username_animation_speed do
        "slow" -> "username-animation-slow"
        "fast" -> "username-animation-fast"
        _ -> "username-animation-normal"
      end
    else
      ""
    end
  end

  defp get_inline_styles(nil), do: ""

  defp get_inline_styles(profile) do
    styles = []

    styles =
      case profile.username_effect do
        effect when effect in ["glow", "neon", "outline", "pixelated"] ->
          glow_color = profile.username_glow_color || UserProfile.default(:username_glow_color)
          intensity = profile.username_glow_intensity || 10
          ["--glow-color: #{glow_color}", "--glow-intensity: #{intensity}px" | styles]

        effect when effect in ["shadow", "double"] ->
          shadow_color =
            profile.username_shadow_color || UserProfile.default(:username_shadow_color)

          ["--shadow-color: #{shadow_color}" | styles]

        "gradient" ->
          gradient_from =
            profile.username_gradient_from || UserProfile.default(:username_glow_color)

          gradient_to =
            profile.username_gradient_to || Elektrine.Theme.default_value("color_secondary")

          ["--gradient-from: #{gradient_from}", "--gradient-to: #{gradient_to}" | styles]

        _ ->
          styles
      end

    Enum.join(styles, "; ")
  end

  defp render_custom_emojis(text) when is_binary(text) do
    text
    |> Elektrine.Emojis.render_custom_emojis()
    |> elem(0)
  end

  defp render_custom_emojis(text), do: text
end
