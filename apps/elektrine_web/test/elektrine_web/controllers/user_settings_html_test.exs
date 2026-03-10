defmodule ElektrineWeb.UserSettingsHTMLTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ElektrineWeb.UserSettingsHTML

  test "backup code page uses a dead-page initializer instead of a LiveView hook" do
    html =
      render_component(&UserSettingsHTML.two_factor_new_codes/1,
        backup_codes: ["AAAA-BBBB", "CCCC-DDDD"]
      )

    assert html =~ "data-backup-codes-printer"
    refute html =~ ~s(phx-hook="BackupCodesPrinter")
  end
end
