defmodule ElektrineWeb.Components.Platform.ZNavTest do
  use Elektrine.DataCase, async: false

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
    assert html =~ "Arblarg"
    assert html =~ "Timeline"
    refute html =~ "Email"
    refute html =~ "Nerve"
    refute html =~ "Nerve"
    refute html =~ "VPN"
  end

  test "applies trust-level nav gating consistently across app wrappers" do
    Application.put_env(:elektrine, :platform_modules, enabled: [:chat, :social, :email])
    assert {:ok, _} = Elektrine.System.set_module_min_trust_level(:maid, 1)
    assert {:ok, _} = Elektrine.System.set_module_min_trust_level(:email, 1)

    current_user = %{trust_level: 0, is_admin: false}

    main_html = render_component(&ZNav.z_nav/1, active_tab: "portal", current_user: current_user)

    chat_html =
      render_component(&ArblargWeb.Components.Platform.ENav.e_nav/1,
        active_tab: "chat",
        current_user: current_user
      )

    for html <- [main_html, chat_html] do
      refute html =~ "Maid"
      refute html =~ "Email"
      assert html =~ "Portal"
      assert html =~ "Arblarg"
    end
  end
end
