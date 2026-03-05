defmodule ElektrineWeb.StorageLive do
  use ElektrineWeb, :live_view
  alias Elektrine.Accounts.Storage
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Elektrine.PubSub, "user:#{user.id}")
    end

    storage_info = Storage.get_storage_info(user.id)
    breakdown = get_storage_breakdown(user.id)

    {:ok,
     socket
     |> assign(:page_title, "Storage Management")
     |> assign(:storage_info, storage_info)
     |> assign(:breakdown, breakdown)
     |> assign(:active_tab, "overview")
     |> assign(:email_attachments, [])
     |> assign(:chat_attachments, [])
     |> assign(:profile_images, [])
     |> assign(:static_site_files, [])}
  end

  @impl true
  def handle_event("change_tab", %{"tab" => tab}, socket) do
    socket =
      case tab do
        "emails" ->
          assign(
            socket,
            :email_attachments,
            get_email_attachments(socket.assigns.current_user.id)
          )

        "chat" ->
          assign(socket, :chat_attachments, get_chat_attachments(socket.assigns.current_user.id))

        "profile" ->
          assign(socket, :profile_images, get_profile_images(socket.assigns.current_user.id))

        "static_sites" ->
          assign(
            socket,
            :static_site_files,
            get_static_site_files(socket.assigns.current_user.id)
          )

        _ ->
          socket
      end

    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event(
        "delete_email_attachment",
        %{"message_id" => message_id, "attachment_id" => attachment_id},
        socket
      ) do
    message_id = String.to_integer(message_id)

    case Elektrine.Email.get_user_message(message_id, socket.assigns.current_user.id) do
      {:ok, message} when is_map_key(message.attachments, attachment_id) ->
        attachment_to_delete = Map.get(message.attachments, attachment_id)

        # Remove the attachment from the message
        updated_attachments = Map.delete(message.attachments, attachment_id)
        has_attachments = map_size(updated_attachments) > 0

        case Elektrine.Email.update_message_attachments(
               message,
               updated_attachments,
               has_attachments
             ) do
          {:ok, _} ->
            maybe_delete_email_attachment_storage(attachment_to_delete)
            Storage.update_user_storage(socket.assigns.current_user.id)

            # Refresh all storage data
            storage_info = Storage.get_storage_info(socket.assigns.current_user.id)
            breakdown = get_storage_breakdown(socket.assigns.current_user.id)

            {:noreply,
             socket
             |> assign(:storage_info, storage_info)
             |> assign(:breakdown, breakdown)
             |> assign(:email_attachments, get_email_attachments(socket.assigns.current_user.id))
             |> put_flash(:info, "Attachment deleted successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete attachment")}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Message not found or access denied")}

      {:ok, _message} ->
        {:noreply, put_flash(socket, :error, "Attachment not found")}
    end
  end

  @impl true
  def handle_event("delete_chat_attachment", %{"message_id" => message_id}, socket) do
    message_id = String.to_integer(message_id)
    message = Elektrine.Repo.get(Elektrine.Messaging.Message, message_id)

    if message && message.sender_id == socket.assigns.current_user.id do
      media_urls_to_delete = message.media_urls || []

      # If message has no content, mark as deleted; otherwise just clear media
      result =
        if is_nil(message.content) || String.trim(message.content || "") == "" do
          # Directly mark as deleted since we already verified ownership
          changeset =
            Elektrine.Messaging.Message.changeset(message, %{
              deleted_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          Elektrine.Repo.update(changeset)
        else
          # Clear media from message but keep the message text
          changeset =
            Elektrine.Messaging.Message.changeset(message, %{media_urls: [], media_metadata: %{}})

          Elektrine.Repo.update(changeset)
        end

      case result do
        {:ok, _} ->
          maybe_delete_chat_media_storage(media_urls_to_delete)
          Storage.update_user_storage(socket.assigns.current_user.id)

          # Refresh all storage data
          storage_info = Storage.get_storage_info(socket.assigns.current_user.id)
          breakdown = get_storage_breakdown(socket.assigns.current_user.id)

          {:noreply,
           socket
           |> assign(:storage_info, storage_info)
           |> assign(:breakdown, breakdown)
           |> assign(:chat_attachments, get_chat_attachments(socket.assigns.current_user.id))
           |> put_flash(:info, "Media deleted successfully")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete media")}
      end
    else
      {:noreply, put_flash(socket, :error, "Unauthorized or message not found")}
    end
  end

  @impl true
  def handle_event("delete_profile_image", %{"type" => type}, socket) do
    user_id = socket.assigns.current_user.id

    {result, file_to_delete} =
      case type do
        "avatar" ->
          {
            Elektrine.Accounts.update_user(socket.assigns.current_user, %{
              avatar: nil,
              avatar_size: 0
            }),
            socket.assigns.current_user.avatar
          }

        "background" ->
          case Elektrine.Profiles.get_user_profile(user_id) do
            nil ->
              {{:error, :not_found}, nil}

            profile ->
              {
                Elektrine.Profiles.update_user_profile(profile, %{
                  background_url: nil,
                  background_size: 0
                }),
                profile.background_url
              }
          end

        "banner" ->
          case Elektrine.Profiles.get_user_profile(user_id) do
            nil ->
              {{:error, :not_found}, nil}

            profile ->
              {
                Elektrine.Profiles.update_user_profile(profile, %{
                  banner_url: nil,
                  banner_size: 0
                }),
                profile.banner_url
              }
          end

        _ ->
          {{:error, :invalid_type}, nil}
      end

    case result do
      {:ok, _} ->
        maybe_delete_uploaded_file(file_to_delete)
        Storage.update_user_storage(user_id)

        # Refresh all storage data
        storage_info = Storage.get_storage_info(user_id)
        breakdown = get_storage_breakdown(user_id)
        fresh_user = Elektrine.Accounts.get_user!(user_id)

        {:noreply,
         socket
         |> assign(:storage_info, storage_info)
         |> assign(:breakdown, breakdown)
         |> assign(:profile_images, get_profile_images(user_id))
         |> assign(:current_user, fresh_user)
         |> put_flash(:info, "Image deleted successfully")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete image")}
    end
  end

  @impl true
  def handle_info({:storage_updated, %{storage_used_bytes: _bytes}}, socket) do
    storage_info = Storage.get_storage_info(socket.assigns.current_user.id)
    breakdown = get_storage_breakdown(socket.assigns.current_user.id)

    {:noreply,
     socket
     |> assign(:storage_info, storage_info)
     |> assign(:breakdown, breakdown)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp get_storage_breakdown(user_id) do
    # Calculate storage by category
    email_storage = Storage.calculate_email_storage(user_id)
    chat_storage = Storage.calculate_chat_storage(user_id)
    profile_storage = Storage.calculate_profile_storage(user_id)
    static_site_storage = Storage.calculate_static_site_storage(user_id)

    [
      %{
        category: "Email Attachments",
        bytes: email_storage,
        icon: "hero-envelope",
        color: "text-primary"
      },
      %{
        category: "Chat Attachments",
        bytes: chat_storage,
        icon: "hero-chat-bubble-left",
        color: "text-success"
      },
      %{
        category: "Profile Images",
        bytes: profile_storage,
        icon: "hero-user-circle",
        color: "text-info"
      },
      %{
        category: "Static Site",
        bytes: static_site_storage,
        icon: "hero-globe-alt",
        color: "text-warning"
      }
    ]
  end

  defp get_email_attachments(user_id) do
    import Ecto.Query
    mailbox = Elektrine.Email.get_user_mailbox(user_id)

    if mailbox do
      from(m in Elektrine.Email.Message,
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

            # Detect image from content_type OR file extension
            is_image =
              String.starts_with?(content_type, "image/") ||
                String.match?(filename, ~r/\.(jpg|jpeg|png|gif|webp)$/i)

            # Generate presigned URL for images
            preview_url =
              if is_image do
                case Elektrine.Email.AttachmentStorage.generate_presigned_url(attachment, 3600) do
                  {:ok, url} -> url
                  _ -> nil
                end
              else
                nil
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

  defp get_chat_attachments(user_id) do
    import Ecto.Query

    from(m in Elektrine.Messaging.Message,
      where:
        m.sender_id == ^user_id and fragment("cardinality(?) > 0", m.media_urls) and
          is_nil(m.deleted_at),
      order_by: [desc: m.inserted_at],
      limit: 100,
      preload: [:conversation]
    )
    |> Elektrine.Repo.all()
    |> Enum.flat_map(fn message ->
      metadata = message.media_metadata || %{}
      # Filter out Giphy URLs - only show uploaded media
      uploaded_urls = Enum.reject(message.media_urls, &String.contains?(&1, "giphy.com"))

      # Skip messages with no uploaded media (only Giphy)
      if Enum.empty?(uploaded_urls) do
        []
      else
        total_size =
          Enum.reduce(uploaded_urls, 0, fn url, acc ->
            case Map.get(metadata, url) do
              %{"size" => size} when is_integer(size) -> acc + size
              %{size: size} when is_integer(size) -> acc + size
              _ -> acc
            end
          end)

        # Generate presigned URL for first image
        preview_url =
          case Enum.take(uploaded_urls, 1) do
            [s3_key] ->
              bucket = Application.get_env(:elektrine, :uploads)[:bucket]
              config = ExAws.Config.new(:s3)

              # Add both inline disposition AND content-type override
              case ExAws.S3.presigned_url(config, :get, bucket, s3_key,
                     expires_in: 3600,
                     virtual_host: false,
                     query_params: [
                       {"response-content-disposition", "inline"},
                       {"response-content-type", "image/jpeg"}
                     ]
                   ) do
                {:ok, signed_url} -> signed_url
                _ -> nil
              end

            _ ->
              nil
          end

        # Extract filename from first URL
        filename =
          case uploaded_urls do
            [url | _] ->
              url
              |> String.split("/")
              |> List.last()
              # Remove user_id and timestamp prefix
              |> String.replace(~r/^\d+_\d+_/, "")

            _ ->
              "Media"
          end

        [
          %{
            message_id: message.id,
            conversation_name: message.conversation.name,
            file_count: length(uploaded_urls),
            total_size: total_size,
            date: message.inserted_at,
            preview_url: preview_url,
            filename: filename
          }
        ]
      end
    end)
    |> Enum.take(50)
  end

  defp get_profile_images(user_id) do
    user = Elektrine.Repo.get(Elektrine.Accounts.User, user_id)
    profile = Elektrine.Profiles.get_user_profile(user_id)

    images = []

    images =
      if user && user.avatar do
        [%{type: "avatar", url: user.avatar, size: user.avatar_size || 0} | images]
      else
        images
      end

    images =
      if profile && profile.background_url do
        [
          %{type: "background", url: profile.background_url, size: profile.background_size || 0}
          | images
        ]
      else
        images
      end

    images =
      if profile && profile.banner_url do
        [%{type: "banner", url: profile.banner_url, size: profile.banner_size || 0} | images]
      else
        images
      end

    images
  end

  defp get_static_site_files(user_id) do
    Elektrine.StaticSites.list_files(user_id)
    |> Enum.map(fn file ->
      %{
        path: file.path,
        size: file.size,
        content_type: file.content_type,
        updated_at: file.updated_at
      }
    end)
    |> Enum.sort_by(& &1.path)
  end

  defp profile_image_url(%{type: "avatar", url: url}) do
    Elektrine.Uploads.avatar_url(url)
  end

  defp profile_image_url(%{type: type, url: url}) when type in ["background", "banner"] do
    Elektrine.Uploads.background_url(url)
  end

  defp profile_image_url(%{url: url}), do: url

  defp maybe_delete_email_attachment_storage(attachment) when is_map(attachment) do
    case Elektrine.Email.AttachmentStorage.delete_attachment(attachment) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete email attachment from storage: #{inspect(reason)}")
        :ok
    end
  end

  defp maybe_delete_email_attachment_storage(_), do: :ok

  defp maybe_delete_chat_media_storage(media_urls) when is_list(media_urls) do
    media_urls
    |> Enum.reject(&String.contains?(&1, "giphy.com"))
    |> Enum.each(&maybe_delete_uploaded_file/1)
  end

  defp maybe_delete_chat_media_storage(_), do: :ok

  defp maybe_delete_uploaded_file(nil), do: :ok
  defp maybe_delete_uploaded_file(""), do: :ok

  defp maybe_delete_uploaded_file(value) when is_binary(value) do
    case Elektrine.Uploads.delete_uploaded_file(value) do
      :ok ->
        :ok

      {:error, reason} when reason in [:invalid_upload_key, :invalid_s3_key] ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete uploaded file #{inspect(value)}: #{inspect(reason)}")
        :ok
    end
  end
end
