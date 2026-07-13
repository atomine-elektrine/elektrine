defmodule Elektrine.ThemeTest do
  use ExUnit.Case, async: true

  alias Elektrine.Theme

  describe "custom_scheme/1" do
    test "derives the light structural theme from a bright background" do
      assert Theme.custom_scheme(%{"color_base_100" => "#f4f1ea"}) == :light
    end

    test "derives the dark structural theme from a dim background" do
      assert Theme.custom_scheme(%{"color_base_100" => "#101820"}) == :dark
    end

    test "falls back to the default palette when no background is set" do
      assert Theme.custom_scheme(%{}) == :light
    end
  end

  describe "email_palette/2" do
    test "applies the custom palette only in custom mode" do
      user = %{theme_mode: "custom", theme_overrides: %{"color_primary" => "#123456"}}
      assert Theme.email_palette(user).button_bg == "#123456"

      pinned = %{user | theme_mode: "dark"}
      assert Theme.email_palette(pinned).button_bg == Theme.default_value("color_primary")
    end

    test "treats plain override maps as active palettes" do
      assert Theme.email_palette(%{"color_primary" => "#123456"}).button_bg == "#123456"
    end
  end

  describe "api_payload/1" do
    test "includes the theme mode alongside the stored palette" do
      payload = Theme.api_payload(%{theme_mode: "dark", theme_overrides: %{}})
      assert payload.mode == "dark"

      assert Theme.api_payload(%{}).mode == "system"
    end
  end
end
