defmodule ElektrineWeb.LayoutsTest do
  use ExUnit.Case, async: true

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
          phoenix_controller: ElektrineWeb.Admin.VPNController,
          phoenix_action: :dashboard
        }
      }

      assert Layouts.build_page_title(%{conn: conn}) == "VPN Dashboard"
    end
  end
end
