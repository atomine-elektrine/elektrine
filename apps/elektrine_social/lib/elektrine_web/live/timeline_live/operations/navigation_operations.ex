defmodule ElektrineWeb.TimelineLive.Operations.NavigationOperations do
  @moduledoc """
  Handles navigation events for the timeline, including navigation to posts, profiles,
  and external links.
  """

  import Phoenix.LiveView

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
      cond do
        is_binary(reply_thread_path) ->
          reply_thread_path

        post && post.federated && is_binary(post.activitypub_id) && post.activitypub_id != "" ->
          "/remote/post/#{URI.encode_www_form(post.activitypub_id)}"

        post && post.federated ->
          "/remote/post/#{id}"

        true ->
          ~p"/timeline/post/#{id}"
      end

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
    anchor = reply_anchor_fragment(id)

    cond do
      parent_id = local_reply_parent_id(post) ->
        "/remote/post/#{parent_id}#{anchor}"

      in_reply_to = metadata_in_reply_to(post) ->
        "/remote/post/#{URI.encode_www_form(in_reply_to)}#{anchor}"

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

  defp reply_anchor_fragment(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> "#message-#{value}"
      _ -> ""
    end
  end

  defp reply_anchor_fragment(id) when is_integer(id), do: "#message-#{id}"
  defp reply_anchor_fragment(_), do: ""

  defp fetch_post_for_navigation(id) do
    with {post_id, ""} <- Integer.parse(to_string(id)),
         %Elektrine.Messaging.Message{} = post <-
           Elektrine.Repo.get(Elektrine.Messaging.Message, post_id) do
      post
    else
      _ -> nil
    end
  end

  defp redirect_to_external_url(socket, url) do
    case SafeExternalURL.normalize(url) do
      {:ok, safe_url} -> redirect(socket, external: safe_url)
      {:error, _reason} -> put_flash(socket, :error, "Invalid external URL")
    end
  end
end
