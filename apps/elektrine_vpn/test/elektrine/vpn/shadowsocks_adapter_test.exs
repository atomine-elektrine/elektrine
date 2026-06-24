defmodule Elektrine.VPN.ShadowsocksAdapterTest do
  use ExUnit.Case, async: true

  alias Elektrine.VPN.ShadowsocksAdapter

  describe "resolve_executable/1" do
    test "resolves bare executable names through the system path" do
      executable = System.find_executable("sh") || System.find_executable("true")

      assert {:ok, ^executable} = ShadowsocksAdapter.resolve_executable(Path.basename(executable))
    end

    test "rejects relative executable paths" do
      assert {:error, :invalid_executable} =
               ShadowsocksAdapter.resolve_executable("./ss-server")

      assert {:error, :invalid_executable} =
               ShadowsocksAdapter.resolve_executable("bin/ss-server")
    end

    test "rejects empty and NUL-containing executable values" do
      assert {:error, :invalid_executable} = ShadowsocksAdapter.resolve_executable("")
      assert {:error, :invalid_executable} = ShadowsocksAdapter.resolve_executable("ss" <> <<0>>)
    end

    test "rejects missing absolute executable paths" do
      assert {:error, {:command_failed, message}} =
               ShadowsocksAdapter.resolve_executable("/definitely/missing/ss-server")

      assert message =~ "executable not found"
    end
  end
end
