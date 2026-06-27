defmodule ElektrineWeb.Features.ProfileTest do
  use ElektrineWeb.FeatureCase, async: false

  feature "user can view their own profile", %{session: session} do
    {session, user} = create_and_login_user(session)

    session
    |> visit("/#{user.handle}")
    |> assert_has(Query.css("#profile-container"))
  end

  feature "user can view settings page", %{session: session} do
    {session, _user} = create_and_login_user(session)

    session
    |> visit("/settings")
    |> assert_has(Query.css("body"))
  end

  feature "profile page renders themed grid and profile styles", %{session: session} do
    {session, user} =
      create_and_login_user(session, %{
        theme_overrides: %{
          "color_base_100" => "#203040",
          "color_base_200" => "#26394a",
          "color_primary" => "#7c9ad0"
        }
      })

    style_snapshot =
      session
      |> visit("/#{user.handle}")
      |> assert_has(Query.css("#profile-container"))
      |> browser_value("""
      const body = document.body;
      const container = document.querySelector("#profile-container");
      const bodyStyle = getComputedStyle(body);
      const containerStyle = getComputedStyle(container);

      return {
        bodyClass: body.className,
        bodyBg: bodyStyle.backgroundColor,
        bodyGrid: bodyStyle.backgroundImage,
        gridColor: bodyStyle.getPropertyValue("--theme-grid-color").trim(),
        profileAccent: containerStyle.getPropertyValue("--profile-accent").trim(),
        profileBackground: containerStyle.backgroundImage,
        profileBg: containerStyle.getPropertyValue("--profile-bg").trim()
      };
      """)

    assert style_snapshot["bodyClass"] =~ "bg-base-100"
    assert style_snapshot["bodyBg"] in ["rgb(32, 48, 64)", "rgba(32, 48, 64, 1)"]
    assert style_snapshot["bodyGrid"] != "none"
    assert style_snapshot["gridColor"] != ""
    assert style_snapshot["profileAccent"] == "var(--color-primary)"
    assert style_snapshot["profileBg"] == "var(--color-base-100)"
    assert style_snapshot["profileBackground"] =~ "linear-gradient"
  end

  defp browser_value(session, script) do
    caller = self()
    ref = make_ref()

    Wallaby.Browser.execute_script(session, script, fn value ->
      send(caller, {ref, value})
    end)

    receive do
      {^ref, value} -> value
    after
      5_000 -> flunk("browser script did not return")
    end
  end
end
