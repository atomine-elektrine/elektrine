defmodule ElektrineWeb.API.MediaAttachmentController do
  @moduledoc """
  API endpoints for media attachments.
  """
  use ElektrineWeb, :controller

  action_fallback ElektrineWeb.FallbackController

  def create(conn, params) do
    user = conn.assigns[:current_user]

    with %Plug.Upload{} = upload <- upload_param(params),
         {:ok, metadata} <- Elektrine.Uploads.upload_timeline_attachment(upload, user.id) do
      attachment =
        metadata
        |> upload_metadata_to_attachment(params)
        |> maybe_put_description(params)

      conn
      |> put_status(:created)
      |> json(format_attachment(attachment))
    else
      nil -> validation_error(conn, "media file is required")
      {:error, reason} -> upload_error(conn, reason)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, key} <- decode_media_id(id),
         true <- media_key_allowed?(key) do
      json(conn, format_attachment(%{"id" => media_id(key), "url" => key}))
    else
      _ -> not_found(conn)
    end
  end

  def update(conn, params) do
    user = conn.assigns[:current_user]

    with media_id when is_binary(media_id) <- media_identifier(params),
         {:ok, attachment} <-
           social().update_media_attachment_metadata(user.id, media_id, params) do
      json(conn, format_attachment(attachment))
    else
      {:error, :empty_media_update} -> validation_error(conn, "media metadata cannot be empty")
      _ -> not_found(conn)
    end
  end

  defp upload_param(params), do: params["file"] || params["media"] || params["upload"]

  defp media_identifier(params) do
    params["id"]
    |> decode_param_media_id()
    |> Kernel.||(params["media_id"] |> decode_param_media_id())
    |> Kernel.||(params["url"])
    |> Kernel.||(params["media_url"])
  end

  defp format_attachment(attachment) do
    url = attachment["url"] |> attachment_url()
    preview_url = attachment["preview_url"] |> attachment_url()
    description = attachment["alt_text"] || attachment["description"] || attachment["name"]

    %{
      id: attachment["id"] || media_id(attachment["url"] || url),
      type: attachment_type(attachment),
      url: url,
      preview_url: preview_url || url,
      description: description,
      meta: attachment_meta(attachment)
    }
  end

  defp attachment_type(%{"mime_type" => "image/" <> _}), do: "image"
  defp attachment_type(%{"mime_type" => "video/" <> _}), do: "video"
  defp attachment_type(%{"mime_type" => "audio/" <> _}), do: "audio"
  defp attachment_type(%{"mediaType" => "image/" <> _}), do: "image"
  defp attachment_type(%{"mediaType" => "video/" <> _}), do: "video"
  defp attachment_type(%{"mediaType" => "audio/" <> _}), do: "audio"

  defp attachment_type(%{"url" => url}) when is_binary(url) do
    case String.downcase(Path.extname(url)) do
      ext when ext in [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif"] -> "image"
      ext when ext in [".mp4", ".mov", ".m4v", ".webm"] -> "video"
      ext when ext in [".mp3", ".m4a", ".ogg", ".wav", ".flac"] -> "audio"
      _ -> "unknown"
    end
  end

  defp attachment_type(_attachment), do: "unknown"

  defp attachment_meta(%{"meta" => meta}) when is_map(meta), do: meta
  defp attachment_meta(%{"focus" => focus}) when is_map(focus), do: %{"focus" => focus}
  defp attachment_meta(_attachment), do: %{}

  defp upload_metadata_to_attachment(metadata, params) do
    key = metadata[:key] || metadata["key"]
    content_type = metadata[:content_type] || metadata["content_type"]
    size = metadata[:size] || metadata["size"]
    filename = metadata[:filename] || metadata["filename"]
    width = metadata[:width] || metadata["width"]
    height = metadata[:height] || metadata["height"]

    %{
      "id" => media_id(key),
      "url" => key,
      "mime_type" => content_type,
      "byte_size" => size,
      "name" => params["description"] || params["text"] || filename,
      "meta" => dimension_meta(width, height)
    }
  end

  defp maybe_put_description(attachment, params) do
    case params["description"] || params["text"] do
      value when is_binary(value) and value != "" -> Map.put(attachment, "description", value)
      _ -> attachment
    end
  end

  defp dimension_meta(width, height) when is_integer(width) and is_integer(height) do
    %{"original" => %{"width" => width, "height" => height}}
  end

  defp dimension_meta(_width, _height), do: %{}

  defp attachment_url(nil), do: nil

  defp attachment_url(key) when is_binary(key) do
    case Elektrine.Uploads.attachment_url(key) do
      {:error, _reason} -> key
      url -> url
    end
  end

  defp attachment_url(value), do: value

  defp media_id(key) when is_binary(key) do
    Base.url_encode64(key, padding: false)
  end

  defp media_id(_key), do: nil

  defp decode_param_media_id(nil), do: nil

  defp decode_param_media_id(value) when is_binary(value) do
    case decode_media_id(value) do
      {:ok, key} -> key
      {:error, :invalid_id} -> value
    end
  end

  defp decode_param_media_id(_value), do: nil

  defp decode_media_id(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, key} when is_binary(key) and key != "" ->
        if String.valid?(key) and media_key_allowed?(key) do
          {:ok, key}
        else
          {:error, :invalid_id}
        end

      _ ->
        {:error, :invalid_id}
    end
  end

  defp decode_media_id(_value), do: {:error, :invalid_id}

  defp media_key_allowed?(key) when is_binary(key) do
    String.starts_with?(key, "timeline-attachments/") or
      String.starts_with?(key, "/uploads/timeline-attachments/")
  end

  defp validation_error(conn, error) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: error})
  end

  defp upload_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: format_upload_error(reason)})
  end

  defp format_upload_error({type, message}) when is_binary(message),
    do: "#{type}: #{message}"

  defp format_upload_error(reason), do: inspect(reason)

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "media attachment not found"})
  end

  defp social, do: Module.concat([Elektrine, Social])
end
