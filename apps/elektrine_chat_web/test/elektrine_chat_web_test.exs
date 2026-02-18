defmodule ElektrineChatWebTest do
  use ExUnit.Case

  test "exposes endpoint and router" do
    assert Code.ensure_loaded?(ElektrineChatWeb.Endpoint)
    assert Code.ensure_loaded?(ElektrineChatWeb.Router)
  end
end
