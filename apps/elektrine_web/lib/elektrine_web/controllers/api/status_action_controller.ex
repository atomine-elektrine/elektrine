defmodule ElektrineWeb.API.StatusActionController do
  @moduledoc """
  API endpoints for timeline status actions.
  """
  use ElektrineWeb, :controller

  alias Elektrine.Repo
  alias Elektrine.Social.Message
  alias Elektrine.Social.Messages
  alias ElektrineWeb.API.StatusJSON

  action_fallback ElektrineWeb.FallbackController

  def create(conn, params) do
    user = conn.assigns[:current_user]

    if scheduled?(params) do
      ElektrineWeb.API.ScheduledStatusController.create(conn, params)
    else
      with content when is_binary(content) <- status_content(params),
           {:ok, created} <-
             social().create_timeline_post(user.id, content, create_opts(params)),
           {:ok, created} <- maybe_create_poll(created, params),
           %Message{} = status <- get_message(created.id) do
        conn
        |> put_status(:created)
        |> json(format_status(status, user.id))
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: ElektrineWeb.ChangesetJSON.error(%{changeset: changeset})})

        {:error, reason} ->
          error(conn, reason)

        _ ->
          error(conn, :empty_post)
      end
    end
  end

  def favourite(conn, %{"id" => id}) do
    run_post_action(conn, id, fn user, message ->
      social().like_post(user.id, message.id)
    end)
  end

  def unfavourite(conn, %{"id" => id}) do
    run_post_action(conn, id, fn user, message ->
      social().unlike_post(user.id, message.id)
    end)
  end

  def reblog(conn, %{"id" => id}) do
    run_post_action(conn, id, fn user, message ->
      social().boost_post(user.id, message.id)
    end)
  end

  def unreblog(conn, %{"id" => id}) do
    run_post_action(conn, id, fn user, message ->
      social().unboost_post(user.id, message.id)
    end)
  end

  def bookmark(conn, %{"id" => id} = params) do
    run_post_action(conn, id, fn user, message ->
      opts =
        params
        |> Map.take(["bookmark_folder_id", "folder_id"])
        |> Enum.map(fn
          {"bookmark_folder_id", value} -> {:bookmark_folder_id, value}
          {"folder_id", value} -> {:folder_id, value}
        end)

      social().save_post(user.id, message.id, opts)
    end)
  end

  def unbookmark(conn, %{"id" => id}) do
    run_post_action(conn, id, fn user, message ->
      social().unsave_post(user.id, message.id)
    end)
  end

  def mute(conn, %{"id" => id}) do
    run_post_action(conn, id, fn user, message ->
      thread_mutes().mute_thread(user.id, message)
    end)
  end

  def unmute(conn, %{"id" => id}) do
    run_post_action(conn, id, fn user, message ->
      _ = thread_mutes().unmute_thread(user.id, message)
      {:ok, nil}
    end)
  end

  def translate(conn, %{"id" => id} = params) do
    case get_visible_message(id, conn.assigns[:current_user].id) do
      %Message{} = message -> json(conn, translation_json(message, params))
      nil -> error(conn, :not_found)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns[:current_user]

    with %Message{} = message <- get_visible_message(id, user.id),
         content when is_binary(content) <- status_content(params),
         {:ok, updated} <- Messages.edit_message(message.id, user.id, content) do
      json(conn, format_status(updated, user.id))
    else
      nil -> error(conn, :not_found)
      {:error, reason} -> error(conn, reason)
      _ -> error(conn, :empty_post)
    end
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns[:current_user]

    with %Message{} = message <- get_visible_message(id, user.id),
         {:ok, deleted} <- Messages.delete_message(message.id, user.id) do
      json(conn, format_status(deleted, user.id))
    else
      nil -> error(conn, :not_found)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp run_post_action(conn, id, fun) do
    user = conn.assigns[:current_user]

    with %Message{} = message <- get_visible_message(id, user.id),
         {:ok, _result} <- fun.(user, message) do
      json(conn, format_status(message, user.id))
    else
      nil -> error(conn, :not_found)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp get_visible_message(id, user_id) do
    case get_message(id) do
      %Message{} = message -> if message_visible?(user_id, message), do: message
      nil -> nil
    end
  end

  defp message_visible?(user_id, message) do
    policy = Module.concat([Elektrine, Social, MessagePolicy])
    Code.ensure_loaded?(policy) and policy.visible?(user_id, message)
  end

  defp get_message(id) do
    Message
    |> Repo.get(id)
    |> Repo.preload(Messages.timeline_feed_preloads() ++ [:message_stat])
    |> case do
      %Message{} = message -> Message.decrypt_content(message)
      nil -> nil
    end
  rescue
    Ecto.Query.CastError -> nil
  end

  defp format_status(%Message{} = message, user_id) do
    status = get_message(message.id) || message

    StatusJSON.format_statuses([status], user_id)
    |> List.first()
    |> Map.put(:muted, thread_mutes().muted?(user_id, status))
  end

  defp translation_json(%Message{} = message, params) do
    %{
      content: message.content || "",
      spoiler_text: message.content_warning || "",
      poll: nil,
      media_attachments: translated_media_attachments(message),
      detected_source_language: source_language(message),
      target_language: target_language(params),
      provider: "none"
    }
  end

  defp translated_media_attachments(%Message{media_metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("attachments", [])
    |> Enum.map(fn attachment ->
      %{
        id: to_string(attachment["id"] || attachment["url"] || ""),
        description: attachment["description"] || attachment["alt_text"] || attachment["name"]
      }
    end)
  end

  defp translated_media_attachments(_message), do: []

  defp source_language(%Message{media_metadata: metadata}) when is_map(metadata) do
    metadata["language"] || metadata[:language] || "und"
  end

  defp source_language(_message), do: "und"

  defp target_language(%{"lang" => language}) when is_binary(language) and language != "",
    do: language

  defp target_language(%{"language" => language}) when is_binary(language) and language != "",
    do: language

  defp target_language(_params), do: nil

  defp status_content(%{"status" => content}) when is_binary(content), do: content
  defp status_content(%{"content" => content}) when is_binary(content), do: content
  defp status_content(%{"text" => content}) when is_binary(content), do: content
  defp status_content(_params), do: nil

  defp create_opts(params) do
    [
      visibility: params["visibility"] || "public",
      media_urls: media_urls(params),
      media_metadata: media_metadata(params),
      content_warning: text_param(params["spoiler_text"] || params["content_warning"]),
      sensitive: truthy?(params["sensitive"]),
      reply_to_id: positive_id(params["in_reply_to_id"]),
      title: text_param(params["title"])
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_create_poll(%Message{} = message, params) do
    case poll_options(params) do
      [] ->
        {:ok, message}

      options ->
        poll = poll_params(params)

        case social().create_poll(
               message.id,
               poll_question(message),
               options,
               closes_at: poll_closes_at(poll),
               allow_multiple: truthy?(poll["multiple"]),
               hide_totals: truthy?(poll["hide_totals"])
             ) do
          {:ok, _poll} -> {:ok, message}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp poll_question(%Message{content: content}) when is_binary(content) and content != "",
    do: content

  defp poll_question(_message), do: "Poll"

  defp poll_options(params) do
    params
    |> poll_params()
    |> Map.get("options", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp poll_params(%{"poll" => poll}) when is_map(poll), do: poll
  defp poll_params(_params), do: %{}

  defp poll_closes_at(%{"expires_in" => seconds}) do
    case parse_int(seconds) do
      seconds when is_integer(seconds) and seconds > 0 ->
        DateTime.utc_now()
        |> DateTime.add(seconds, :second)
        |> DateTime.truncate(:second)

      _ ->
        nil
    end
  end

  defp poll_closes_at(%{"expires_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      _ -> nil
    end
  end

  defp poll_closes_at(_poll), do: nil

  defp media_urls(params) do
    params
    |> Map.take(["media_ids", "media_ids[]", "media_urls", "media_urls[]"])
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(&normalize_string_list/1)
    |> Enum.map(&decode_media_reference/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp media_metadata(params) do
    urls = media_urls(params)

    if urls == [] do
      %{}
    else
      %{
        "attachments" =>
          Enum.map(urls, fn url ->
            %{"id" => url, "url" => url}
          end)
      }
    end
  end

  defp decode_media_reference(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> decoded
      :error -> value
    end
  end

  defp decode_media_reference(_value), do: nil

  defp normalize_string_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp normalize_string_list(value) when is_integer(value), do: [to_string(value)]
  defp normalize_string_list(_value), do: []

  defp scheduled?(%{"scheduled_at" => value}) when is_binary(value), do: String.trim(value) != ""
  defp scheduled?(_params), do: false

  defp positive_id(value) when is_integer(value) and value > 0, do: value

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp positive_id(_value), do: nil

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp text_param(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text_param(_value), do: nil

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_value), do: false

  defp error(conn, reason) when reason in [:not_found, :not_authorized, :unauthorized] do
    conn
    |> put_status(:not_found)
    |> json(%{error: "not found"})
  end

  defp error(conn, :empty_post) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "status cannot be shared"})
  end

  defp error(conn, _reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "unprocessable entity"})
  end

  defp social, do: Module.concat([Elektrine, Social])
  defp thread_mutes, do: Module.concat([Elektrine, Social, ThreadMutes])
end
