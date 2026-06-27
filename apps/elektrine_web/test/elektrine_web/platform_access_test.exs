defmodule ElektrineWeb.PlatformAccessTest do
  use ExUnit.Case, async: true

  alias ElektrineWeb.PlatformAccess

  describe "required_module_for_path/1" do
    test "maps optional module route prefixes" do
      assert PlatformAccess.required_module_for_path("/email/view/123") == :email
      assert PlatformAccess.required_module_for_path("/api/ext/v1/chat/conversations") == :chat
      assert PlatformAccess.required_module_for_path("/timeline/post/123") == :social
      assert PlatformAccess.required_module_for_path("/account/nerve") == :nerve
      assert PlatformAccess.required_module_for_path("/api/ext/v1/dns/zones") == :dns
      assert PlatformAccess.required_module_for_path("/vpn/servers") == :vpn
      assert PlatformAccess.required_module_for_path("/uptime") == :uptime
    end

    test "leaves shared routes unrestricted" do
      assert PlatformAccess.required_module_for_path("/portal") == nil
      assert PlatformAccess.required_module_for_path("/drive/share/token") == nil
      assert PlatformAccess.required_module_for_path(nil) == nil
    end
  end

  describe "required_module_for_view/1" do
    test "maps optional module live views" do
      assert PlatformAccess.required_module_for_view(ElektrineEmailWeb.EmailLive.Index) == :email
      assert PlatformAccess.required_module_for_view(ArblargWeb.ChatLive.Index) == :chat

      assert PlatformAccess.required_module_for_view(ElektrineSocialWeb.TimelineLive.Index) ==
               :social

      assert PlatformAccess.required_module_for_view(ElektrineNerveWeb.NerveLive) == :nerve
      assert PlatformAccess.required_module_for_view(ElektrineDNSWeb.DNSLive.Index) == :dns
      assert PlatformAccess.required_module_for_view(ElektrineVPNWeb.VPNLive.Index) == :vpn

      assert PlatformAccess.required_module_for_view(ElektrineUptimeWeb.UptimeLive.Index) ==
               :uptime
    end
  end

  describe "required_access_module_for_view/1" do
    test "maps finer-grained access modules" do
      assert PlatformAccess.required_access_module_for_view(ElektrineWeb.PortalLive.Index) ==
               :portal

      assert PlatformAccess.required_access_module_for_view(ElektrineSocialWeb.GalleryLive.Index) ==
               :gallery

      assert PlatformAccess.required_access_module_for_view(ElektrineSocialWeb.ListLive.Show) ==
               :lists

      assert PlatformAccess.required_access_module_for_view(ElektrineWeb.DriveLive) == :drive
    end
  end
end
