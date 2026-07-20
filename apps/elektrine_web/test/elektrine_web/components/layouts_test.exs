defmodule ElektrineWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ElektrineWeb.Layouts

  describe "build_page_title/1" do
    test "does not raise for live view conn without phoenix_controller private key" do
      conn = %Plug.Conn{
        request_path: "/search",
        private: %{
          phoenix_live_view:
            {ElektrineWeb.SearchLive, [action: :index, router: ElektrineWeb.Router], %{}}
        }
      }

      assert Layouts.build_page_title(%{conn: conn}) == "Elektrine"
    end

    test "uses admin controller title when controller private metadata is present" do
      conn = %Plug.Conn{
        request_path: "/pripyat/vpn",
        private: %{
          phoenix_controller: ElektrineVPNWeb.Admin.VPNController,
          phoenix_action: :dashboard
        }
      }

      assert Layouts.build_page_title(%{conn: conn}) == "VPN Dashboard"
    end
  end

  describe "full_width_main?/1" do
    test "returns true for app surfaces that manage their own page width" do
      assert Layouts.full_width_main?(%{current_url: "https://example.com/timeline"})
      assert Layouts.full_width_main?(%{current_url: "https://example.com/gallery"})
      assert Layouts.full_width_main?(%{current_url: "https://example.com/videos"})
      assert Layouts.full_width_main?(%{current_url: "https://example.com/email"})
      assert Layouts.full_width_main?(%{current_url: "https://example.com/communities"})
      assert Layouts.full_width_main?(%{current_url: "https://example.com/d/elixir"})
      assert Layouts.full_width_main?(%{current_url: "https://example.com/kairo"})
      assert Layouts.full_width_main?(%{current_url: "https://example.com/kairo?s=1"})
    end

    test "returns true from LiveView module when current_url is missing" do
      assert Layouts.full_width_main?(%{
               socket: %{view: ElektrineWeb.KairoLive.Index, host_uri: %URI{host: "localhost"}}
             })

      assert Layouts.full_width_main?(%{
               socket: %{view: ElektrineWeb.ChatLive.Index, host_uri: %URI{host: "localhost"}}
             })
    end

    test "does not treat host_uri without a route path as home for layout width" do
      # host_uri is not a route; without current_url/view markers, fall back safely
      refute Layouts.full_width_main?(%{
               socket: %{view: ElektrineWeb.UserSettingsLive, host_uri: %URI{host: "localhost"}}
             })
    end

    test "returns false for standard account pages" do
      refute Layouts.full_width_main?(%{current_url: "https://example.com/account"})
      refute Layouts.full_width_main?(%{current_url: "https://example.com/login"})
    end
  end

  describe "current_url/1" do
    test "returns only safe absolute URLs" do
      assert Layouts.current_url(%{current_url: " https://example.com/timeline "}) ==
               "https://example.com/timeline"

      refute Layouts.current_url(%{current_url: "javascript:alert(1)"})
      refute Layouts.current_url(%{current_url: "https://user:pass@example.com/"})

      refute Layouts.current_url(%{
               current_url: "https://example.com/\r\nLocation:https://evil.test"
             })
    end
  end

  describe "og_image_url/1" do
    test "allows safe absolute and local image URLs" do
      assert Layouts.og_image_url(%{og_image: "https://cdn.example/og.png"}) ==
               "https://cdn.example/og.png"

      assert Layouts.og_image_url(%{og_image: "/images/custom-og.png"}) =~ "/images/custom-og.png"
    end

    test "falls back to the default image for unsafe image URLs" do
      default = Layouts.og_image_url(%{})

      assert Layouts.og_image_url(%{og_image: "javascript:alert(1)"}) == default
      assert Layouts.og_image_url(%{og_image: "https://user:pass@example.com/og.png"}) == default
      assert Layouts.og_image_url(%{og_image: "//evil.test/og.png"}) == default
    end
  end

  test "root layout uses a dead-page timezone detector" do
    html =
      render_component(&Layouts.root/1,
        inner_content: "",
        page_title: "Test"
      )

    assert html =~ "data-timezone-detector"
    refute html =~ ~s(phx-hook="TimezoneDetector")
  end

  test "root layout leaves anonymous visitors on the browser-local theme" do
    html =
      render_component(&Layouts.root/1,
        inner_content: "",
        page_title: "Test"
      )

    assert html =~ ~s(data-theme="dark")
    refute html =~ "data-theme-mode="
    assert html =~ ~s|localStorage.getItem("elektrine:theme")|
    assert html =~ ~s|matchMedia("(prefers-color-scheme: light)")|
  end

  test "custom mode uses the palette's background to select its structural theme" do
    dark_html =
      render_component(&Layouts.root/1,
        inner_content: "",
        page_title: "Dark custom theme",
        current_user: %{
          theme_mode: "custom",
          theme_overrides: %{"color_base_100" => "#101820", "color_primary" => "#f5d90a"}
        }
      )

    light_html =
      render_component(&Layouts.root/1,
        inner_content: "",
        page_title: "Light custom theme",
        current_user: %{
          theme_mode: "custom",
          theme_overrides: %{"color_base_100" => "#f4f1ea"}
        }
      )

    assert dark_html =~ ~s(data-theme="dark")
    assert dark_html =~ ~s(data-theme-mode="custom")
    assert dark_html =~ ~s(--theme-override-color-primary: #f5d90a)
    assert dark_html =~ ~s(--theme-override-color-primary-content: #101317)
    assert light_html =~ ~s(data-theme="light")
    assert light_html =~ ~s(data-theme-mode="custom")
  end

  test "pinned day and night modes ignore the custom palette" do
    light_html =
      render_component(&Layouts.root/1,
        inner_content: "",
        page_title: "Day",
        current_user: %{
          theme_mode: "light",
          theme_overrides: %{"color_base_100" => "#101820"}
        }
      )

    dark_html =
      render_component(&Layouts.root/1,
        inner_content: "",
        page_title: "Night",
        current_user: %{
          theme_mode: "dark",
          theme_overrides: %{"color_base_100" => "#f4f1ea"}
        }
      )

    assert light_html =~ ~s(data-theme="light")
    assert light_html =~ ~s(data-theme-mode="light")
    refute light_html =~ "--theme-override-color"
    assert dark_html =~ ~s(data-theme="dark")
    assert dark_html =~ ~s(data-theme-mode="dark")
    refute dark_html =~ "--theme-override-color"
  end

  test "system mode follows the OS scheme and ignores the custom palette" do
    html =
      render_component(&Layouts.root/1,
        inner_content: "",
        page_title: "System",
        current_user: %{
          theme_mode: "system",
          theme_overrides: %{"color_base_100" => "#f4f1ea"}
        }
      )

    assert html =~ ~s(data-theme-mode="system")
    refute html =~ "--theme-override-color"
  end

  test "root layout respects assign-driven robots meta values" do
    html =
      render_component(&Layouts.root/1,
        inner_content: "",
        page_title: "Test",
        meta_robots: "noindex, nofollow"
      )

    assert html =~ ~s(<meta name="robots" content="noindex, nofollow")
  end

  test "custom mode emits the full effective palette for the grid background" do
    html =
      render_component(&Layouts.root/1,
        inner_content: "",
        page_title: "Test",
        current_user: %{
          theme_mode: "custom",
          theme_overrides: %{"color_base_100" => "#203040", "color_info" => "#405060"}
        },
        current_url: "https://example.com/settings"
      )

    assert html =~ ~s(--theme-override-color-base-100: #203040)
    assert html =~ ~s(--theme-override-color-info: #405060)
    assert html =~ ~s(--theme-override-color-base-200: #edf1f5)
    assert html =~ ~s(data-grid="cyan")
  end

  test "body grid background uses theme CSS variables instead of DaisyUI oklch aliases" do
    css =
      Path.expand("../../../../elektrine/assets/css/base.css", __DIR__)
      |> File.read!()

    assert css =~ "body.bg-base-100"
    assert css =~ "background-color: var(--color-base-100)"
    refute css =~ "background-color: oklch(var(--b1))"
  end

  test "light theme gives controls distinct filled surfaces" do
    base_css =
      Path.expand("../../../../elektrine/assets/css/base.css", __DIR__)
      |> File.read!()

    components_css =
      Path.expand("../../../../elektrine/assets/css/components.css", __DIR__)
      |> File.read!()

    assert base_css =~ "--theme-input-bg:"

    assert base_css =~
             "--color-primary-content: var(--theme-override-color-primary-content, #ffffff)"

    assert components_css =~ ~s|html[data-theme="light"] .btn-primary:not(.btn-outline)|
    assert components_css =~ "background-color: var(--theme-input-bg"
  end

  test "optimistic vote counts stay hidden outside the click loading state" do
    css =
      Path.expand("../../../../elektrine/assets/css/components.css", __DIR__)
      |> File.read!()

    assert css =~ ".vote-score-pending { display: none !important;"

    assert css =~
             ".vote-up-button.phx-click-loading + .vote-score .vote-score-pending { display: inline !important;"
  end
end
