defmodule ElektrineWeb.StorageEmail do
  @moduledoc """
  Email-owned storage helpers used by the shared storage shell.
  """

  import Ecto.Query

  alias Elektrine.Accounts.Storage
  alias Elektrine.Email

  require Logger

  def list_attachments(user_id) do
    mailbox = Email.get_user_mailbox(user_id)

    if mailbox do
      from(m in Email.Message,
        where: m.mailbox_id == ^mailbox.id and m.has_attachments == true,
        order_by: [desc: m.inserted_at],
        limit: 50
      )
      |> Elektrine.Repo.all()
      |> Enum.flat_map(fn message ->
        if message.attachments && is_map(message.attachments) do
          message.attachments
          |> Enum.map(fn {key, attachment} ->
            filename = Map.get(attachment, "filename", "unknown")
            content_type = Map.get(attachment, "content_type", "")

            is_image =
              String.starts_with?(content_type, "image/") ||
                String.match?(filename, ~r/\.(jpg|jpeg|png|gif|webp)$/i)

            preview_url =
              if is_image do
                "/email/message/#{message.id}/attachment/#{key}/download"
              end

            %{
              message_id: message.id,
              attachment_id: key,
              filename: filename,
              size: Map.get(attachment, "size", 0),
              date: message.inserted_at,
              from: message.from,
              is_image: is_image,
              preview_url: preview_url,
              content_type: content_type
            }
          end)
        else
          []
        end
      end)
    else
      []
    end
  end

  def delete_attachment(user_id, message_id, attachment_id) do
    case Email.get_user_message(message_id, user_id) do
      {:ok, message} when is_map_key(message.attachments, attachment_id) ->
        attachment_to_delete = Map.get(message.attachments, attachment_id)
        updated_attachments = Map.delete(message.attachments, attachment_id)
        has_attachments = map_size(updated_attachments) > 0

        case Email.update_message_attachments(message, updated_attachments, has_attachments) do
          {:ok, _} ->
            maybe_delete_email_attachment_storage(attachment_to_delete)
            Storage.update_user_storage(user_id)
            :ok

          {:error, _} ->
            {:error, :update_failed}
        end

      {:error, _} ->
        {:error, :message_not_found}

      {:ok, _message} ->
        {:error, :attachment_not_found}
    end
  end

  defp maybe_delete_email_attachment_storage(attachment) when is_map(attachment) do
    case Email.AttachmentStorage.delete_attachment(attachment) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete email attachment from storage: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_delete_email_attachment_storage(_), do: :ok
end
