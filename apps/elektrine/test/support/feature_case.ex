defmodule ElektrineWeb.FeatureCase do
  @moduledoc """
  This module defines the test case to be used by
  browser-based feature tests using Wallaby.

  Use this for end-to-end tests that need real browser interaction.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature
      @moduletag :feature

      alias Elektrine.Repo
      alias Wallaby.Query
      import Ecto
      import Ecto.Changeset
      import Ecto.Query, except: [update: 2, update: 3]

      @default_password "Password123!"

      # Helper to create a user and log them in
      def create_and_login_user(session, attrs \\ %{}) do
        user = create_test_user(attrs)
        session = login_user(session, user)
        {session, user}
      end

      def create_test_user(attrs \\ %{}) do
        unique_id = System.unique_integer([:positive])

        default_attrs = %{
          username: "testuser#{unique_id}",
          email: "test#{unique_id}@z.org",
          password: @default_password,
          password_confirmation: @default_password,
          handle: "testuser#{unique_id}"
        }

        {:ok, user} =
          default_attrs
          |> Map.merge(attrs)
          |> Elektrine.Accounts.create_user()

        # Mark onboarding as completed so tests can access the full app
        {:ok, user} =
          user
          |> Ecto.Changeset.change(%{
            onboarding_completed: true,
            onboarding_completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
          |> Repo.update()

        user
      end

      def login_user(session, user) do
        session
        |> visit("/login")
        |> fill_in(Query.css("#login-form_username"), with: user.username)
        |> fill_in(Query.css("#login-form_password"), with: @default_password)
        |> click(Query.button("Log in"))
        |> wait_for_liveview()
      end

      @doc """
      Wait for LiveView to connect by checking for the phx-connected attribute.
      This helps avoid race conditions when navigating between pages.
      """
      def wait_for_liveview(session) do
        # Only block when this page is actually a LiveView. Controller-rendered pages
        # may not have a LiveView root and should continue immediately.
        if has_selector?(session, "[data-phx-main]") do
          wait_for_liveview_connected(session, System.monotonic_time(:millisecond) + 10_000)
        else
          session
        end
      end

      @doc """
      Navigate and wait for LiveView to connect.
      """
      def visit_and_wait(session, path) do
        session
        |> visit(path)
        |> wait_for_liveview()
      end

      defp wait_for_liveview_connected(session, deadline_ms) do
        connected? =
          has_selector?(session, "body.phx-connected") or
            has_selector?(session, "[data-phx-main].phx-connected")

        cond do
          connected? ->
            session

          System.monotonic_time(:millisecond) >= deadline_ms ->
            session

          true ->
            :timer.sleep(50)
            wait_for_liveview_connected(session, deadline_ms)
        end
      end

      defp has_selector?(session, selector) do
        session
        |> Wallaby.Browser.all(Query.css(selector))
        |> Enum.any?()
      end
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Elektrine.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Elektrine.Repo, {:shared, self()})
    end

    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(Elektrine.Repo, self())
    {:ok, session} = Wallaby.start_session(metadata: metadata)
    # Make feature tests deterministic: keep a consistent, desktop-sized viewport.
    session = Wallaby.Browser.resize_window(session, 1280, 800)

    {:ok, session: session}
  end
end
