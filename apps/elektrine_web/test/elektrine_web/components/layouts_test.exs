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
      assert Layouts.full_width_main?(%{current_url: "https://example.com/email"})
      assert Layouts.full_width_main?(%{current_url: "https://example.com/communities"})
      assert Layouts.full_width_main?(%{current_url: "https://example.com/d/elixir"})
    end

    test "returns false for standard account pages" do
      refute Layouts.full_width_main?(%{current_url: "https://example.com/account"})
      refute Layouts.full_width_main?(%{current_url: "https://example.com/login"})
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
end
