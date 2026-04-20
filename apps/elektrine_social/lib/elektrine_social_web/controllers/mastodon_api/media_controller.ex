defmodule ElektrineSocialWeb.MastodonAPI.MediaController do
  @moduledoc """
  Mastodon-compatible media upload endpoints backed by timeline attachment uploads.
  """

  use ElektrineSocialWeb, :controller

  alias Elektrine.Uploads

  action_fallback(ElektrineSocialWeb.MastodonAPI.FallbackController)

  def create(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def create(%{assigns: %{user: user}} = conn, %{"file" => %Plug.Upload{} = upload}) do
    with {:ok, uploaded} <- Uploads.upload_timeline_attachment(upload, user.id) do
      conn
      |> put_status(:ok)
      |> json(render_media(uploaded, nil))
    end
  end

  def create(_conn, _params), do: {:error, :unprocessable_entity, "Missing file upload"}

  def update(%{assigns: %{user: nil}}, _params), do: {:error, :unauthorized}

  def update(conn, %{"id" => id} = params) do
    json(
      conn,
      render_media(%{key: id, content_type: params["content_type"]}, params["description"])
    )
  end

  defp render_media(uploaded, description) do
    %{
      id: uploaded.key,
      type: detect_media_type(uploaded.content_type),
      url: Uploads.attachment_url(uploaded.key),
      preview_url: Uploads.attachment_url(uploaded.key),
      remote_url: nil,
      preview_remote_url: nil,
      text_url: nil,
      meta: %{},
      description: description,
      blurhash: nil
    }
  end

  defp detect_media_type(nil), do: "image"

  defp detect_media_type(content_type) do
    cond do
      String.starts_with?(content_type, "video/") -> "video"
      String.starts_with?(content_type, "audio/") -> "audio"
      true -> "image"
    end
  end
end
