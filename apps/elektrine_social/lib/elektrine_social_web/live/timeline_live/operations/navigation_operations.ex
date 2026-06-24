defmodule ElektrineSocialWeb.TimelineLive.Operations.NavigationOperations do
  @moduledoc """
  Handles navigation events for the timeline, including navigation to posts, profiles,
  and external links.
  """

  import Phoenix.LiveView

  alias Elektrine.Paths
  alias Elektrine.Security.SafeExternalURL

  use Phoenix.VerifiedRoutes,
    endpoint: ElektrineWeb.Endpoint,
    router: ElektrineWeb.Router

  # Navigate to a timeline post detail page by post ID.
  def handle_event("navigate_to_post", %{"id" => id}, socket) do
    post =
      Enum.find(socket.assigns[:timeline_posts] || [], fn post ->
        to_string(post.id) == to_string(id)
      end) || fetch_post_for_navigation(id)

    {:noreply, push_navigate(socket, to: timeline_post_path(post || id))}
  end

  def handle_event("navigate_to_post", _params, socket) do
    {:noreply, socket}
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
        Paths.post_path(post)
      else
        Paths.post_path(id)
      end

    {:noreply, push_navigate(socket, to: path)}
  end

  # Navigate to an embedded post by ID.
  def handle_event("navigate_to_embedded_post", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: Paths.post_path(id))}
  end

  # Navigate to an embedded post by URL.
  def handle_event("navigate_to_embedded_post", %{"url" => url}, socket) do
    ElektrineWeb.SafeLiveNavigation.noreply(socket, url)
  end

  # Navigate to remote post view by ActivityPub ID (passed as url).
  def handle_event("navigate_to_remote_post", %{"url" => activitypub_id}, socket)
      when is_binary(activitypub_id) and activitypub_id != "" do
    {:noreply, ElektrineWeb.PostNavigation.navigate(socket, activitypub_id)}
  end

  # Navigate to remote post view by post_id.
  def handle_event("navigate_to_remote_post", %{"post_id" => post_id}, socket) do
    post =
      Enum.find(socket.assigns[:timeline_posts] || [], &(to_string(&1.id) == to_string(post_id)))

    if post do
      {:noreply, push_navigate(socket, to: Paths.post_path(post))}
    else
      {:noreply, ElektrineWeb.PostNavigation.navigate(socket, post_id)}
    end
  end

  def handle_event("navigate_to_remote_post", _params, socket) do
    {:noreply, socket}
  end

  # Open an external link in the current window.
  def handle_event("open_external_link", %{"url" => url}, socket)
      when is_binary(url) and url != "" do
    {:noreply, redirect_to_external_url(socket, url)}
  end

  def handle_event("open_external_link", _params, socket) do
    {:noreply, socket}
  end

  # Open an external post URL in a new window.
  def handle_event("open_external_post", %{"url" => url}, socket) do
    case SafeExternalURL.normalize(url) do
      {:ok, safe_url} -> {:noreply, push_event(socket, "open_url", %{url: safe_url})}
      {:error, _reason} -> {:noreply, put_flash(socket, :error, "Invalid external URL")}
    end
  end

  # Navigate to the original content location.
  def handle_event("navigate_to_origin", %{"url" => url}, socket) do
    ElektrineWeb.SafeLiveNavigation.noreply(socket, url)
  end

  # Navigate to a local user's profile page.
  def handle_event("navigate_to_profile", params, socket) do
    ElektrineWeb.ProfileNavigation.navigate(socket, params)
  end

  # Navigate to a remote user's profile page.
  def handle_event(
        "navigate_to_remote_profile",
        %{"username" => username, "domain" => domain},
        socket
      ) do
    {:noreply, push_navigate(socket, to: "/remote/#{username}@#{domain}")}
  end

  defp fetch_post_for_navigation(id) do
    with {post_id, ""} <- Integer.parse(to_string(id)),
         %Elektrine.Social.Message{} = post <-
           Elektrine.Repo.get(Elektrine.Social.Message, post_id) do
      Elektrine.Repo.preload(post, [:conversation])
    else
      _ -> nil
    end
  end

  defp timeline_post_path(%{id: id}) when is_integer(id), do: Paths.remote_post_path(id)
  defp timeline_post_path(id) when is_integer(id), do: Paths.remote_post_path(id)

  defp timeline_post_path(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> Paths.remote_post_path(int)
      _ -> Paths.post_path(id)
    end
  end

  defp timeline_post_path(value), do: Paths.post_path(value)

  defp redirect_to_external_url(socket, url) do
    case SafeExternalURL.normalize(url) do
      {:ok, safe_url} -> redirect(socket, external: safe_url)
      {:error, _reason} -> put_flash(socket, :error, "Invalid external URL")
    end
  end
end
