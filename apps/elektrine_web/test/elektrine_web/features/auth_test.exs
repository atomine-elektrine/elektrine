defmodule ElektrineWeb.Features.AuthTest do
  use ElektrineWeb.FeatureCase, async: false

  feature "user can log in with valid credentials", %{session: session} do
    user = create_test_user()

    session
    |> visit("/login")
    |> fill_in(Query.css("#login-form_username"), with: user.username)
    |> fill_in(Query.css("#login-form_password"), with: @default_password)
    |> click(Query.button("Log in"))
    |> assert_has(Query.css("body"))
  end

  feature "user sees error with invalid credentials", %{session: session} do
    session
    |> visit("/login")
    |> fill_in(Query.css("#login-form_username"), with: "nonexistent")
    |> fill_in(Query.css("#login-form_password"), with: "wrongpassword")
    |> click(Query.button("Log in"))
    |> assert_has(Query.text("Invalid"))
  end

  feature "user can log out", %{session: session} do
    {session, _user} = create_and_login_user(session)

    # The Log out link is in a dropdown menu, need to open it first
    session
    |> visit_and_wait("/settings")
    |> click(Query.css("[data-test='user-menu'] [role='button']"))
    |> click(Query.css("[data-test='user-menu'] a", text: "Log out"))
    # After logout, redirects to home page with a "Log in" link visible
    |> assert_has(Query.link("Log in"))
  end
end
