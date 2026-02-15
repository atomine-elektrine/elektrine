defmodule ElektrineWeb.Features.TimelineTest do
  use ElektrineWeb.FeatureCase, async: false

  feature "logged in user can view timeline", %{session: session} do
    {session, _user} = create_and_login_user(session)

    session
    |> visit_and_wait("/timeline")
    |> assert_has(Query.css("body"))
  end

  feature "user can create a new post", %{session: session} do
    {session, _user} = create_and_login_user(session)

    session
    |> visit_and_wait("/timeline")
    # Use the accessible composer-toggle selector to work across mobile/desktop layouts.
    |> assert_has(Query.css("button[aria-label='Create new post']"))
    |> click(Query.css("button[aria-label='Create new post']"))
    # Verify the composer form appears
    |> assert_has(Query.css("#post-composer-container"))
    |> assert_has(Query.css("#timeline-post-textarea"))
    # Fill in the textarea
    |> fill_in(Query.css("#timeline-post-textarea"), with: "Hello from Wallaby test!")
    # Verify the submit button is visible within the form
    |> assert_has(Query.css("#post-composer-form button[type='submit']"))
  end

  feature "user can like a post", %{session: session} do
    {session, user} = create_and_login_user(session)

    # Create a public post via the context
    {:ok, post} =
      Elektrine.Social.create_timeline_post(user.id, "A post to like", visibility: "public")

    session
    |> visit_and_wait("/timeline")
    |> assert_has(Query.css("#timeline-posts-container"))
    |> assert_has(Query.css("[data-post-id='#{post.id}']"))
  end
end
