defmodule ElektrineWeb.Features.ChatTest do
  use ElektrineWeb.FeatureCase, async: false

  feature "user can view chat page", %{session: session} do
    {session, _user} = create_and_login_user(session)

    session
    |> visit("/chat")
    |> assert_has(Query.css("body"))
  end

  feature "user can view friends page", %{session: session} do
    {session, _user} = create_and_login_user(session)

    session
    |> visit("/friends")
    |> assert_has(Query.css("body"))
  end
end
