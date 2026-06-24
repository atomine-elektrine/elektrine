defmodule Elektrine.ACME.WildcardRenewalWorkerTest do
  use ExUnit.Case, async: false

  alias Elektrine.ACME.WildcardRenewalWorker

  @env_keys [
    "ACME_HOME",
    "ACME_RENEW_COMMAND",
    "ACME_SH_BIN",
    "ACME_WILDCARD_RENEWAL_ENABLED",
    "ARGS_FILE"
  ]

  setup do
    previous_env =
      Map.new(@env_keys, fn key ->
        {key, System.get_env(key)}
      end)

    tmp_dir =
      Path.join(System.tmp_dir!(), "elektrine-acme-worker-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      restore_env(previous_env)
      File.rm_rf(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "runs acme.sh directly with argv and ignores legacy shell command env", %{tmp_dir: tmp_dir} do
    acme_home = Path.join(tmp_dir, "acme home;touch injected")
    File.mkdir_p!(acme_home)

    acme_sh = Path.join(acme_home, "acme.sh")
    args_file = Path.join(tmp_dir, "args")
    injected_file = Path.join(tmp_dir, "injected")

    File.write!(acme_sh, """
    #!/bin/sh
    printf '%s\\n' "$@" > "$ARGS_FILE"
    """)

    File.chmod!(acme_sh, 0o700)

    System.put_env("ACME_WILDCARD_RENEWAL_ENABLED", "true")
    System.put_env("ACME_HOME", acme_home)
    System.put_env("ACME_SH_BIN", acme_sh)
    System.put_env("ACME_RENEW_COMMAND", "touch #{injected_file}")
    System.put_env("ARGS_FILE", args_file)

    assert :ok = WildcardRenewalWorker.perform(%Oban.Job{})

    assert File.read!(args_file) == "--cron\n--home\n#{acme_home}\n"
    refute File.exists?(injected_file)
  end

  test "rejects relative configured acme executable path" do
    System.put_env("ACME_WILDCARD_RENEWAL_ENABLED", "true")
    System.put_env("ACME_SH_BIN", "acme.sh")

    assert {:error, :invalid_executable} = WildcardRenewalWorker.perform(%Oban.Job{})
  end

  defp restore_env(previous_env) do
    Enum.each(previous_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end
end
