defmodule ElektrineSocialWeb.MastodonAPI.StatusController do
  @moduledoc """
  Mastodon-compatible status endpoints backed by Elektrine's timeline posts.
  """

  use ElektrineSocialWeb, :controller

  alias Elektrine.Social
  alias Elektrine.Social.Drafts
  alias Elektrine.Social.Messages
  alias ElektrineSocialWeb.MastodonAPI.StatusView

  action_fallback(ElektrineSocialWeb.MastodonAPI.FallbackController)

  def show(conn, %{"id" => id}) do
    with {:ok, post} <- fetch_post(id) do
      json(conn, render_status(post, conn.assigns[:user]))
    end
  end

  def context(conn, %{"id" => id}) do
    with {:ok, post} <- fetch_post(id) do
      json(conn, %{
        ancestors: post |> build_ancestors() |> StatusView.render_statuses(conn.assigns[:user]),
        descendants:
          post |> build_descendants() |> StatusView.render_statuses(conn.assigns[:user])
      })
    end
  end

  def create(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def create(%{assigns: %{user: user}} = conn, params) do
    status = params["status"] || ""
    visibility = normalize_visibility(params["visibility"])
    in_reply_to_id = parse_int(params["in_reply_to_id"])
    media_ids = normalize_media_ids(params["media_ids"])
    scheduled_at = parse_datetime(params["scheduled_at"])
    poll_params = params["poll"] || %{}

    if scheduled_at do
      with {:ok, draft} <-
             Drafts.create_draft(user.id,
               content: status,
               visibility: visibility,
               media_urls: media_ids,
               content_warning: params["spoiler_text"],
               scheduled_at: scheduled_at
             ) do
        conn
        |> put_status(:accepted)
        |> json(render_scheduled_status(draft))
      end
    else
      opts =
        []
        |> Keyword.put(:visibility, visibility)
        |> Keyword.put(:media_urls, media_ids)
        |> maybe_put_reply_to(in_reply_to_id)
        |> maybe_put_content_warning(params["spoiler_text"])
        |> maybe_put_sensitive(params["sensitive"])

      with {:ok, post} <- Social.create_timeline_post(user.id, status, opts),
           {:ok, post} <- maybe_create_poll(post, poll_params) do
        conn
        |> put_status(:created)
        |> json(render_status(post, user))
      end
    end
  end

  def delete(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def delete(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, post} <- fetch_post(id),
         {:ok, _deleted} <- Elektrine.Messaging.delete_message(post.id, user.id) do
      json(conn, render_status(post, user))
    else
      {:error, :unauthorized} -> {:error, :forbidden}
      error -> error
    end
  end

  def favourite(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def favourite(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, post} <- fetch_post(id),
         {:ok, _} <- like_or_accept_existing(user.id, post.id) do
      json(conn, render_status(Messages.get_timeline_post!(post.id, force: true), user))
    end
  end

  def unfavourite(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def unfavourite(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, post} <- fetch_post(id),
         {:ok, _} <- unlike_or_accept_missing(user.id, post.id) do
      json(conn, render_status(Messages.get_timeline_post!(post.id, force: true), user))
    end
  end

  def reblog(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def reblog(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, post} <- fetch_post(id),
         {:ok, _} <- reblog_or_accept_existing(user.id, post.id) do
      json(conn, render_status(Messages.get_timeline_post!(post.id, force: true), user))
    end
  end

  def unreblog(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def unreblog(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, post} <- fetch_post(id),
         {:ok, _} <- unreblog_or_accept_missing(user.id, post.id) do
      json(conn, render_status(Messages.get_timeline_post!(post.id, force: true), user))
    end
  end

  def bookmark(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def bookmark(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, post} <- fetch_post(id),
         {:ok, _} <- bookmark_or_accept_existing(user.id, post.id) do
      json(conn, render_status(Messages.get_timeline_post!(post.id, force: true), user))
    end
  end

  def unbookmark(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def unbookmark(%{assigns: %{user: user}} = conn, %{"id" => id}) do
    with {:ok, post} <- fetch_post(id),
         {:ok, _} <- unbookmark_or_accept_missing(user.id, post.id) do
      json(conn, render_status(Messages.get_timeline_post!(post.id, force: true), user))
    end
  end

  defp fetch_post(id) do
    case parse_int(id) do
      nil ->
        {:error, :not_found}

      post_id ->
        case Messages.get_timeline_post(post_id) do
          nil -> {:error, :not_found}
          post -> {:ok, post}
        end
    end
  end

  defp build_ancestors(%{reply_to_id: nil}), do: []

  defp build_ancestors(%{reply_to_id: reply_to_id}) do
    case Messages.get_timeline_post(reply_to_id) do
      nil -> []
      parent -> build_ancestors(parent) ++ [parent]
    end
  end

  defp build_descendants(post) do
    Social.get_unified_replies(post.id)
  end

  defp render_status(post, user) do
    StatusView.render_status(post, user)
  end

  defp normalize_visibility(value) when value in ["public", "unlisted", "private", "direct"],
    do: value

  defp normalize_visibility("private"), do: "private"
  defp normalize_visibility("direct"), do: "private"
  defp normalize_visibility("unlisted"), do: "unlisted"
  defp normalize_visibility(_), do: "public"

  defp maybe_put_reply_to(opts, nil), do: opts
  defp maybe_put_reply_to(opts, id), do: Keyword.put(opts, :reply_to_id, id)

  defp maybe_put_content_warning(opts, value) when is_binary(value) and value != "",
    do: Keyword.put(opts, :content_warning, value)

  defp maybe_put_content_warning(opts, _), do: opts

  defp maybe_put_sensitive(opts, value) when value in [true, "true"],
    do: Keyword.put(opts, :sensitive, true)

  defp maybe_put_sensitive(opts, _), do: opts

  defp like_or_accept_existing(user_id, post_id) do
    case Social.like_post(user_id, post_id) do
      {:ok, result} -> {:ok, result}
      {:error, %Ecto.Changeset{}} -> {:ok, :already_liked}
      error -> error
    end
  end

  defp unlike_or_accept_missing(user_id, post_id) do
    case Social.unlike_post(user_id, post_id) do
      {:ok, result} -> {:ok, result}
      {:error, :not_liked} -> {:ok, :not_liked}
      error -> error
    end
  end

  defp reblog_or_accept_existing(user_id, post_id) do
    case Social.boost_post(user_id, post_id) do
      {:ok, result} -> {:ok, result}
      {:error, :already_boosted} -> {:ok, :already_boosted}
      error -> error
    end
  end

  defp unreblog_or_accept_missing(user_id, post_id) do
    case Social.unboost_post(user_id, post_id) do
      {:ok, result} -> {:ok, result}
      {:error, :not_boosted} -> {:ok, :not_boosted}
      error -> error
    end
  end

  defp bookmark_or_accept_existing(user_id, post_id) do
    case Social.save_post(user_id, post_id) do
      {:ok, result} -> {:ok, result}
      {:error, %Ecto.Changeset{}} -> {:ok, :already_bookmarked}
      error -> error
    end
  end

  defp unbookmark_or_accept_missing(user_id, post_id) do
    case Social.unsave_post(user_id, post_id) do
      {:ok, result} -> {:ok, result}
      {:error, :not_saved} -> {:ok, :not_saved}
      error -> error
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_media_ids(media_ids) when is_list(media_ids) do
    Enum.filter(media_ids, &is_binary/1)
  end

  defp normalize_media_ids(media_id) when is_binary(media_id), do: [media_id]
  defp normalize_media_ids(_), do: []

  defp maybe_create_poll(post, %{"options" => options} = poll_params)
       when is_list(options) and length(options) > 1 do
    case Social.create_poll(
           post.id,
           poll_params["question"] || "Poll",
           options,
           allow_multiple: poll_params["multiple"] in [true, "true"],
           closes_at: parse_poll_expiry(poll_params["expires_in"])
         ) do
      {:ok, _poll} -> {:ok, Messages.get_timeline_post!(post.id, force: true)}
      error -> error
    end
  end

  defp maybe_create_poll(post, _poll_params), do: {:ok, post}

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_poll_expiry(nil), do: nil

  defp parse_poll_expiry(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> DateTime.add(DateTime.utc_now(), seconds, :second)
      _ -> nil
    end
  end

  defp render_scheduled_status(draft) do
    %{
      id: to_string(draft.id),
      scheduled_at: draft.scheduled_at && DateTime.to_iso8601(draft.scheduled_at),
      params: %{
        text: draft.content || "",
        media_ids: draft.media_urls || [],
        sensitive: draft.sensitive || false,
        spoiler_text: draft.content_warning || "",
        visibility: draft.visibility || "public"
      }
    }
  end
end
