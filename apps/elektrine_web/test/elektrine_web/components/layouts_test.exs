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

  test "root layout respects assign-driven robots meta values" do
    html =
      render_component(&Layouts.root/1,
        inner_content: "",
        page_title: "Test",
        meta_robots: "noindex, nofollow"
      )

    assert html =~ ~s(<meta name="robots" content="noindex, nofollow")
  end

  test "root layout exposes user theme overrides to the grid background" do
    html =
      render_component(&Layouts.root/1,
        inner_content: "",
        page_title: "Test",
        current_user: %{
          theme_overrides: %{"color_base_100" => "#203040", "color_info" => "#405060"}
        },
        current_url: "https://example.com/settings"
      )

    assert html =~ ~s(--theme-override-color-base-100: #203040)
    assert html =~ ~s(--theme-override-color-info: #405060)
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
end
