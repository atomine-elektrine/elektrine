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

    reply_thread_path = reply_thread_path(post, id)

    path =
      if is_binary(reply_thread_path), do: reply_thread_path, else: timeline_post_path(post || id)

    {:noreply, push_navigate(socket, to: path)}
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
    {:noreply, push_navigate(socket, to: url)}
  end

  # Navigate to remote post view by ActivityPub ID (passed as url).
  def handle_event("navigate_to_remote_post", %{"url" => activitypub_id}, socket)
      when is_binary(activitypub_id) and activitypub_id != "" do
    {:noreply, push_navigate(socket, to: "/remote/post/#{URI.encode_www_form(activitypub_id)}")}
  end

  # Navigate to remote post view by post_id.
  def handle_event("navigate_to_remote_post", %{"post_id" => post_id}, socket) do
    post =
      Enum.find(socket.assigns[:timeline_posts] || [], &(to_string(&1.id) == to_string(post_id)))

    path =
      case post do
        %{activitypub_id: activitypub_id}
        when is_binary(activitypub_id) and activitypub_id != "" ->
          "/remote/post/#{URI.encode_www_form(activitypub_id)}"

        _ ->
          timeline_post_path(post_id)
      end

    {:noreply, push_navigate(socket, to: path)}
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

  defp reply_thread_path(nil, _id), do: nil

  defp reply_thread_path(post, id) do
    cond do
      parent_id = local_reply_parent_id(post) ->
        parent_path = Paths.remote_post_path(parent_id)
        parent_path <> Paths.post_anchor(id)

      in_reply_to = metadata_in_reply_to(post) ->
        Paths.anchored_post_path(in_reply_to, id)

      true ->
        nil
    end
  end

  defp local_reply_parent_id(%{reply_to_id: reply_to_id}) when is_integer(reply_to_id),
    do: reply_to_id

  defp local_reply_parent_id(%{reply_to_id: reply_to_id}) when is_binary(reply_to_id) do
    case Integer.parse(reply_to_id) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp local_reply_parent_id(_), do: nil

  defp metadata_in_reply_to(post) do
    metadata = Map.get(post, :media_metadata) || Map.get(post, "media_metadata")

    if is_map(metadata) do
      [
        Map.get(metadata, "inReplyTo"),
        Map.get(metadata, "in_reply_to"),
        Map.get(metadata, :inReplyTo),
        Map.get(metadata, :in_reply_to)
      ]
      |> Enum.find_value(&normalize_in_reply_to_ref/1)
    else
      nil
    end
  end

  defp normalize_in_reply_to_ref(%{"id" => id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{"href" => href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref(%{id: id}), do: normalize_in_reply_to_ref(id)
  defp normalize_in_reply_to_ref(%{href: href}), do: normalize_in_reply_to_ref(href)
  defp normalize_in_reply_to_ref([first | _]), do: normalize_in_reply_to_ref(first)

  defp normalize_in_reply_to_ref(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_in_reply_to_ref(_), do: nil

  defp fetch_post_for_navigation(id) do
    with {post_id, ""} <- Integer.parse(to_string(id)),
         %Elektrine.Social.Message{} = post <-
           Elektrine.Repo.get(Elektrine.Social.Message, post_id) do
      Elektrine.Repo.preload(post, [:conversation])
    else
      _ -> nil
    end
  end

  defp timeline_post_path(%{federated: true, activitypub_id: activitypub_id})
       when is_binary(activitypub_id) and activitypub_id != "",
       do: "/remote/post/#{URI.encode_www_form(activitypub_id)}"

  defp timeline_post_path(%{id: id}) when is_integer(id), do: timeline_post_path(id)
  defp timeline_post_path(id) when is_integer(id), do: "/timeline/post/#{id}"

  defp timeline_post_path(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> timeline_post_path(int)
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
