defmodule Elektrine.RuntimeEnvTest do
  use ExUnit.Case, async: true

  alias Elektrine.RuntimeEnv

  setup do
    previous_environment = Application.get_env(:elektrine, :environment)

    on_exit(fn ->
      if is_nil(previous_environment) do
        Application.delete_env(:elektrine, :environment)
      else
        Application.put_env(:elektrine, :environment, previous_environment)
      end
    end)

    :ok
  end

  test "present trims blank values" do
    assert RuntimeEnv.present("FOO", %{"FOO" => "  value  "}) == "value"
    assert RuntimeEnv.present("FOO", %{"FOO" => "   "}) == nil
  end

  test "first_present returns first populated env value" do
    env = %{"B" => "second", "C" => "third"}

    assert RuntimeEnv.first_present(["A", "B", "C"], env) == "second"
  end

  test "optional_boolean parses common boolean env values" do
    assert RuntimeEnv.optional_boolean("FLAG", %{"FLAG" => "true"}) == true
    assert RuntimeEnv.optional_boolean("FLAG", %{"FLAG" => "false"}) == false
    assert RuntimeEnv.optional_boolean("FLAG", %{"FLAG" => "maybe"}) == nil
  end

  test "prod? and dev_or_test? reflect configured environment" do
    Application.put_env(:elektrine, :environment, :prod)
    assert RuntimeEnv.prod?()
    refute RuntimeEnv.dev_or_test?()

    Application.put_env(:elektrine, :environment, :test)
    refute RuntimeEnv.prod?()
    assert RuntimeEnv.dev_or_test?()
  end

  test "enforce_https? reflects app config" do
    previous_enforce_https = Application.get_env(:elektrine, :enforce_https)

    on_exit(fn ->
      if is_nil(previous_enforce_https) do
        Application.delete_env(:elektrine, :enforce_https)
      else
        Application.put_env(:elektrine, :enforce_https, previous_enforce_https)
      end
    end)

    Application.put_env(:elektrine, :enforce_https, true)
    assert RuntimeEnv.enforce_https?()

    Application.put_env(:elektrine, :enforce_https, false)
    refute RuntimeEnv.enforce_https?()
  end
end
