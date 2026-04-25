defmodule ElektrineWeb.Components.Platform.ZNavTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias ElektrineWeb.Components.Platform.ZNav

  setup do
    original = Application.get_env(:elektrine, :platform_modules)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:elektrine, :platform_modules)
      else
        Application.put_env(:elektrine, :platform_modules, original)
      end
    end)

    :ok
  end

  test "hides disabled module tabs" do
    Application.put_env(:elektrine, :platform_modules, enabled: [:chat, :social])

    html = render_component(&ZNav.z_nav/1, active_tab: "portal")

    assert html =~ "Portal"
    assert html =~ "Chat"
    assert html =~ "Timeline"
    refute html =~ "Email"
    refute html =~ "Vault"
    refute html =~ "VPN"
  end
end
