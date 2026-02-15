defmodule ElektrineWeb.TimelineLive.Operations.NavigationOperations do
  @moduledoc """
  Handles navigation events for the timeline, including navigation to posts, profiles,
  and external links.
  """

  import Phoenix.LiveView

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  # Navigate to a timeline post detail page by post ID.
  def handle_event("navigate_to_post", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{id}")}
  end

  # Navigate from image/media cards.
  # Local posts should always open local detail; federated posts open remote detail.
  def handle_event("navigate_to_gallery_post", %{"id" => id}, socket) do
    post =
      Enum.find(socket.assigns.timeline_posts || [], fn p ->
        to_string(p.id) == to_string(id)
      end)

    path =
      if post && post.federated && post.activitypub_id do
        "/remote/post/#{URI.encode_www_form(post.activitypub_id)}"
      else
        ~p"/timeline/post/#{id}"
      end

    {:noreply, push_navigate(socket, to: path)}
  end

  # Navigate to an embedded post by ID.
  def handle_event("navigate_to_embedded_post", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/timeline/post/#{id}")}
  end

  # Navigate to an embedded post by URL.
  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket) do
    {:noreply, push_navigate(socket, to: url)}
  end

  # Navigate to remote post view by ActivityPub ID (passed as url).
  def handle_event("navigate_to_remote_post", %{"url" => activitypub_id}, socket)
      when is_binary(activitypub_id) and activitypub_id != "" do
    encoded = URI.encode_www_form(activitypub_id)
    {:noreply, push_navigate(socket, to: "/remote/post/#{encoded}")}
  end

  # Navigate to remote post view by post_id.
  def handle_event("navigate_to_remote_post", %{"post_id" => post_id}, socket) do
    {:noreply, push_navigate(socket, to: "/remote/post/#{post_id}")}
  end

  def handle_event("navigate_to_remote_post", _params, socket) do
    {:noreply, socket}
  end

  # Open an external link in the current window.
  def handle_event("open_external_link", %{"url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, redirect(socket, external: url)}
  end

  def handle_event("open_external_link", _params, socket) do
    {:noreply, socket}
  end

  # Open an external post URL in a new window.
  def handle_event("open_external_post", %{"url" => url}, socket) do
    {:noreply, push_event(socket, "open_url", %{url: url})}
  end

  # Navigate to the original content location.
  def handle_event("navigate_to_origin", %{"url" => url}, socket) do
    {:noreply, push_navigate(socket, to: url)}
  end

  # Navigate to a local user's profile page.
  def handle_event("navigate_to_profile", params, socket) do
    handle = params["handle"] || params["username"]
    {:noreply, redirect(socket, to: ~p"/#{handle}")}
  end

  # Navigate to a remote user's profile page.
  def handle_event(
        "navigate_to_remote_profile",
        %{"username" => username, "domain" => domain},
        socket
      ) do
    {:noreply, push_navigate(socket, to: "/remote/#{username}@#{domain}")}
  end
end
