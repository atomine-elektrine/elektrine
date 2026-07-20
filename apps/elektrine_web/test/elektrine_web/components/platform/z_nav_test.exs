defmodule ElektrineWeb.Components.Platform.ZNavTest do
  use Elektrine.DataCase, async: false

  import Phoenix.LiveViewTest

  alias Elektrine.Platform.ENav
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
    refute html =~ "Nerve"
    refute html =~ "Nerve"
    refute html =~ "VPN"
  end

  test "friends belongs to the secondary nav items" do
    refute Enum.any?(ENav.primary_items(), &(&1.id == "friends"))
    assert Enum.any?(ENav.secondary_items(), &(&1.id == "friends"))
  end

  test "secondary items render in the More menu instead of a second row" do
    html =
      render_component(&ZNav.z_nav/1,
        active_tab: "portal",
        current_user: %{id: 1, is_admin: true, trust_level: 4}
      )

    assert html =~ "More navigation"
    assert html =~ "Account and tools"
    assert html =~ "Account"
    assert html =~ "Friends"
    refute html =~ "border-t border-base-300"
  end

  test "active primary tab keeps its label visible while others are xl-only" do
    html = render_component(&ZNav.z_nav/1, active_tab: "chat")

    assert html =~ ~s(aria-label="Chat")
    assert html =~ "hidden min-w-0 max-w-[9rem] truncate xl:inline"
  end

  test "tabs keep touch-friendly hit areas and icons on small screens" do
    html =
      render_component(&ZNav.z_nav/1,
        active_tab: "portal",
        current_user: %{id: 1, is_admin: true, trust_level: 4}
      )

    assert html =~ "min-h-9 min-w-9"
    assert html =~ "h-5 w-5 shrink-0 transition-colors sm:h-4 sm:w-4"
  end

  test "renders as a flush underline strip instead of a card" do
    html = render_component(&ZNav.z_nav/1, active_tab: "portal")

    refute html =~ "panel-card"
    assert html =~ "-mt-6"
    assert html =~ "border-b border-base-300/70"
    assert html =~ "after:bg-primary"
  end
end
