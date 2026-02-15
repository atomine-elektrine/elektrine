defmodule ElektrineWeb.Features.EmailTest do
  use ElektrineWeb.FeatureCase, async: false

  feature "logged in user can view inbox", %{session: session} do
    {session, _user} = create_and_login_user(session)

    session
    |> visit("/inbox")
    |> assert_has(Query.css("body"))
  end

  feature "user can view compose page", %{session: session} do
    {session, _user} = create_and_login_user(session)

    session
    |> visit("/inbox/compose")
    |> assert_has(Query.css("body"))
  end
end
