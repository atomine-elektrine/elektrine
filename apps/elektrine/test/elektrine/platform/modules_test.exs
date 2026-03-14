defmodule Elektrine.Platform.ModulesTest do
  use ExUnit.Case, async: false

  alias Elektrine.Platform.Modules

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

  test "normalizes hoster module lists from strings" do
    assert Modules.normalize_enabled_modules("chat, email, password-manager, vpn") == [
             :chat,
             :email,
             :vault,
             :vpn
           ]
  end

  test "drops unknown module names and de-duplicates values" do
    assert Modules.normalize_enabled_modules([:chat, "chat", "unknown", "social"]) == [
             :chat,
             :social
           ]
  end

  test "supports disabling all optional modules" do
    assert Modules.normalize_enabled_modules("none") == []
    assert Modules.normalize_enabled_modules("") == []
  end

  test "reads enabled modules from runtime config" do
    Application.put_env(:elektrine, :platform_modules, enabled: "chat,email")

    assert Modules.enabled() == [:chat, :email]
    assert Modules.enabled?(:chat)
    refute Modules.enabled?(:vpn)
  end
end
