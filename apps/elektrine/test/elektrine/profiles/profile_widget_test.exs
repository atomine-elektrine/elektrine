defmodule Elektrine.Profiles.ProfileWidgetTest do
  use ExUnit.Case, async: true

  alias Elektrine.Profiles.ProfileWidget

  test "discord status widgets require real Discord snowflake IDs" do
    changeset =
      ProfileWidget.changeset(%ProfileWidget{}, %{
        profile_id: 1,
        widget_type: "discord_status",
        content: "123"
      })

    refute changeset.valid?
    assert %{content: ["must be a valid Discord user ID"]} = errors_on(changeset)
  end

  test "discord status widgets accept 17-20 digit IDs" do
    changeset =
      ProfileWidget.changeset(%ProfileWidget{}, %{
        profile_id: 1,
        widget_type: "discord_status",
        content: "94490510688792576"
      })

    assert changeset.valid?
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
