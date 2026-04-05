defmodule ElektrineChatWeb.ChatLive.Operations.CallInfoOperationsTest do
  use ExUnit.Case, async: true

  alias ElektrineChatWeb.ChatLive.Operations.CallInfoOperations

  test "route_info/2 routes call terminal events and marks them as processed" do
    socket = socket_fixture()
    call = %{id: 123}

    assert {:handled, {:noreply, updated_socket}} =
             CallInfoOperations.route_info({:call_missed, call}, socket)

    assert MapSet.member?(updated_socket.assigns.processed_call_events, {"call_missed", 123})
  end

  test "route_info/2 returns :unhandled for unrelated messages" do
    assert :unhandled == CallInfoOperations.route_info(:unknown, socket_fixture())
  end

  defp socket_fixture do
    %Phoenix.LiveView.Socket{
      assigns: %{
        call: %{
          incoming_call: nil,
          active_call: nil,
          status: nil,
          audio_enabled: true,
          video_enabled: true
        },
        ui: %{show_incoming_call: false},
        processed_call_events: MapSet.new(),
        __changed__: %{}
      }
    }
  end
end
