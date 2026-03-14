defmodule Elektrine.PushTest do
  use ExUnit.Case, async: true

  alias Elektrine.Push

  defmodule ConnectedPresence do
    def get_by_key("mobile:users", "123"), do: [%{metas: [%{user_id: 123}]}]
    def get_by_key(_topic, _key), do: []
  end

  defmodule UnavailablePresence do
    def get_by_key(_topic, _key) do
      raise ArgumentError, "the table identifier does not refer to an existing ETS table"
    end
  end

  test "returns false when web runtime component is disabled" do
    refute Push.user_has_active_connection?(123,
             web_enabled?: false,
             presence_running?: true,
             presence_module: ConnectedPresence
           )
  end

  test "returns false when the presence process is not running" do
    refute Push.user_has_active_connection?(123,
             web_enabled?: true,
             presence_running?: false,
             presence_module: ConnectedPresence
           )
  end

  test "returns false when the presence tracker ETS table is unavailable" do
    refute Push.user_has_active_connection?(123,
             web_enabled?: true,
             presence_running?: true,
             presence_module: UnavailablePresence
           )
  end

  test "returns true when presence lookup finds an active connection" do
    assert Push.user_has_active_connection?(123,
             web_enabled?: true,
             presence_running?: true,
             presence_module: ConnectedPresence
           )
  end
end
