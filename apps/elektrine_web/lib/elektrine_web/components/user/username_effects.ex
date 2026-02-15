defmodule ElektrineWeb.Components.User.UsernameEffects do
  use Phoenix.Component
  import ElektrineWeb.Components.User.VerificationBadge
  import ElektrineWeb.Components.TrustLevelBadge

  @doc """
  Applies username text effects from user's profile customization.

  ## Examples

      <.username_with_effects user={@user} class="font-bold" />
      <.username_with_effects user={@user} display_name={true} />
  """
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
    # Handle nil user (federated posts with no sender)
    if assigns.user == nil do
      assigns =
        assign(assigns, %{
          username: "unknown",
          effect_class: "",
          animation_class: "",
          inline_styles: "",
          verified_color: "#1d9bf0",
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
    # Handle different user data structures
    {user, profile} =
      cond do
        # Plain map without profile (e.g., from member queries)
        is_map(assigns.user) && !Map.has_key?(assigns.user, :__struct__) ->
          # Try to load full user if we have user_id
          full_user =
            if Map.has_key?(assigns.user, :user_id) do
              Elektrine.Repo.get(Elektrine.Accounts.User, assigns.user.user_id)
              |> Elektrine.Repo.preload(:profile)
            else
              # Convert map to struct-like access
              assigns.user
            end

          {full_user || assigns.user, full_user && full_user.profile}

        # Ecto struct - check if profile is loaded
        Map.has_key?(assigns.user, :__struct__) && Map.has_key?(assigns.user, :profile) ->
          user =
            if Ecto.assoc_loaded?(assigns.user.profile) do
              assigns.user
            else
              Elektrine.Repo.preload(assigns.user, :profile)
            end

          {user, user.profile}

        # Fallback
        true ->
          {assigns.user, nil}
      end

    username =
      if assigns.display_name && profile && profile.display_name do
        profile.display_name
      else
        Map.get(user, :handle) || Map.get(user, :username)
      end

    effect_class = get_effect_class(profile)
    animation_class = get_animation_class(profile)
    inline_styles = get_inline_styles(profile)

    # Get verified badge color from profile tick_color or default
    verified_color =
      if profile && profile.tick_color do
        profile.tick_color
      else
        # Twitter blue
        "#1d9bf0"
      end

    # Check if user is verified (handle both struct and map)
    is_verified = Map.get(user, :verified, false)

    assigns =
      assign(assigns, %{
        username: username,
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
        {@username}
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
    # Effects that support animation speed
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
          glow_color = profile.username_glow_color || "#8b5cf6"
          intensity = profile.username_glow_intensity || 10
          ["--glow-color: #{glow_color}", "--glow-intensity: #{intensity}px" | styles]

        effect when effect in ["shadow", "double"] ->
          shadow_color = profile.username_shadow_color || "#000000"
          ["--shadow-color: #{shadow_color}" | styles]

        "gradient" ->
          gradient_from = profile.username_gradient_from || "#8b5cf6"
          gradient_to = profile.username_gradient_to || "#ec4899"
          ["--gradient-from: #{gradient_from}", "--gradient-to: #{gradient_to}" | styles]

        _ ->
          styles
      end

    Enum.join(styles, "; ")
  end
end
