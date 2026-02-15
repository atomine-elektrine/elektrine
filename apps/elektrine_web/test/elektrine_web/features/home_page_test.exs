defmodule ElektrineWeb.Features.HomePageTest do
  use ElektrineWeb.FeatureCase, async: false

  feature "visiting the home page", %{session: session} do
    session
    |> visit("/")
    |> assert_has(Query.css("body"))
  end

  feature "home page has login link", %{session: session} do
    session
    |> visit("/")
    |> assert_has(Query.link("Sign in"))
  end

  feature "can navigate to login page", %{session: session} do
    session
    |> visit("/")
    |> click(Query.link("Sign in"))
    |> assert_has(Query.css("#login-form"))
  end
end
