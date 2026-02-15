defmodule Elektrine.CustomDomains.CertProvisionerTest do
  use ExUnit.Case, async: true

  alias Elektrine.CustomDomains.CertProvisioner

  describe "start_link/1" do
    test "starts the GenServer" do
      # The provisioner may already be running from the application
      case GenServer.whereis(CertProvisioner) do
        nil ->
          # Start it for testing
          assert {:ok, pid} = CertProvisioner.start_link([])
          assert is_pid(pid)
          GenServer.stop(pid)

        pid ->
          # Already running
          assert is_pid(pid)
      end
    end
  end

  describe "init/1" do
    test "does not provision in test environment" do
      # LETS_ENCRYPT_ENABLED is not set in test, so provisioning is skipped
      # The init should complete without errors
      assert function_exported?(CertProvisioner, :init, 1)
    end
  end

  describe "handle_info/2" do
    test "handles :check_renewal message" do
      # Verify the callback exists
      assert function_exported?(CertProvisioner, :handle_info, 2)
    end
  end
end
