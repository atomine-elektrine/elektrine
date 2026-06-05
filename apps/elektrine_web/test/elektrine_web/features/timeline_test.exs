defmodule ElektrineSocialWeb.Features.TimelineTest do
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
    |> assert_has(Query.css("[data-test='desktop-create-post-button']"))
    |> click(Query.css("[data-test='desktop-create-post-button']"))
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
    post_text = "A post to like #{System.unique_integer([:positive])}"

    # Create a public post via the context
    {:ok, _post} =
      Elektrine.Social.create_timeline_post(user.id, post_text, visibility: "public")

    session
    |> visit_and_wait("/timeline")
    |> assert_has(Query.css("#timeline-posts-container"))
    |> assert_has(Query.text(post_text))
  end
end
