defmodule ElektrineWeb.Features.ProfileTest do
  use ElektrineWeb.FeatureCase, async: false

  feature "user can view their own profile", %{session: session} do
    {session, user} = create_and_login_user(session)

    session
    |> visit("/#{user.handle}")
    |> assert_has(Query.css("body"))
  end

  feature "user can view settings page", %{session: session} do
    {session, _user} = create_and_login_user(session)

    session
    |> visit("/settings")
    |> assert_has(Query.css("body"))
  end
end
