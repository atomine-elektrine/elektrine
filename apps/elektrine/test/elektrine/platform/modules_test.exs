defmodule Elektrine.Platform.ModulesTest do
  use ExUnit.Case, async: false

  alias Elektrine.Platform.Modules

  setup do
    original = Application.get_env(:elektrine, :platform_modules)
    original_compiled = Application.get_env(:elektrine, :compiled_platform_modules)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:elektrine, :platform_modules)
      else
        Application.put_env(:elektrine, :platform_modules, original)
      end

      if is_nil(original_compiled) do
        Application.delete_env(:elektrine, :compiled_platform_modules)
      else
        Application.put_env(:elektrine, :compiled_platform_modules, original_compiled)
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

    expected =
      if Code.ensure_loaded?(Elektrine.Email) do
        [:chat, :email]
      else
        [:chat]
      end

    assert Modules.enabled() == expected
    assert Modules.enabled?(:chat)
    refute Modules.enabled?(:vpn)
  end

  test "filters compiled modules by code availability" do
    Application.put_env(:elektrine, :compiled_platform_modules, [:chat, :email])
    Application.put_env(:elektrine, :platform_modules, enabled: [:chat, :email])

    expected =
      if Code.ensure_loaded?(Elektrine.Email) do
        [:chat, :email]
      else
        [:chat]
      end

    assert Modules.compiled() == expected
    assert Modules.enabled() == expected
  end
end
