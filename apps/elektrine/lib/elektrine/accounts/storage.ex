defmodule Elektrine.Accounts.Storage do
  @moduledoc """
  Centralized storage tracking for user uploads across the entire application.
  Tracks storage usage from emails, chat attachments, profile images, etc.
  """

  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Accounts.User
  alias Elektrine.Email.Message

  @doc """
  Calculates total storage used by a user across all sources.
  Includes: email messages, chat attachments, profile images, etc.
  """
  def calculate_user_storage(user_id) do
    # Email storage (mailbox messages)
    email_storage = calculate_email_storage(user_id)

    # Chat message media storage
    chat_storage = calculate_chat_storage(user_id)

    # Profile images and backgrounds
    profile_storage = calculate_profile_storage(user_id)

    # Static site files
    static_site_storage = calculate_static_site_storage(user_id)

    total = email_storage + chat_storage + profile_storage + static_site_storage

    total
  end

  @doc """
  Updates the storage_used_bytes for a user.
  """
  def update_user_storage(user_id) do
    total_bytes = calculate_user_storage(user_id)

    from(u in User, where: u.id == ^user_id)
    |> Repo.update_all(
      set: [
        storage_used_bytes: total_bytes,
        storage_last_calculated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      ]
    )

    # Invalidate storage cache
    Elektrine.AppCache.invalidate_storage_cache(user_id)

    # Broadcast storage update to LiveViews
    Phoenix.PubSub.broadcast!(
      Elektrine.PubSub,
      "user:#{user_id}",
      {:storage_updated,
       %{
         storage_used_bytes: total_bytes,
         user_id: user_id
       }}
    )

    {:ok, total_bytes}
  end

  @doc """
  Checks if a user would exceed their storage limit with additional bytes.
  """
  def would_exceed_limit?(user_id, additional_bytes) do
    user = Repo.get(User, user_id)

    if user do
      current_storage = user.storage_used_bytes || 0
      # 500MB default
      limit = user.storage_limit_bytes || 524_288_000

      current_storage + additional_bytes > limit
    else
      false
    end
  end

  @doc """
  Gets storage info for a user including usage percentage and formatted sizes.
  """
  def get_storage_info(user_id) do
    user = Repo.get(User, user_id)

    if user do
      used = user.storage_used_bytes || 0
      limit = user.storage_limit_bytes || 26_214_400

      %{
        used_bytes: used,
        limit_bytes: limit,
        used_formatted: format_bytes(used),
        limit_formatted: format_bytes(limit),
        percentage: if(limit > 0, do: used / limit, else: 0),
        over_limit: used > limit,
        available_bytes: max(0, limit - used)
      }
    else
      nil
    end
  end

  # Public calculation functions for storage management page

  def calculate_email_storage(user_id) do
    # Get user's mailbox
    case Elektrine.Email.get_user_mailbox(user_id) do
      nil ->
        0

      mailbox ->
        # Sum all text/html body sizes and actual attachment file sizes
        messages =
          Message
          |> where([m], m.mailbox_id == ^mailbox.id)
          |> select([m], %{
            text_size: coalesce(fragment("length(?)", m.text_body), 0),
            html_size: coalesce(fragment("length(?)", m.html_body), 0),
            subject_size: coalesce(fragment("length(?)", m.subject), 0),
            from_size: coalesce(fragment("length(?)", m.from), 0),
            to_size: coalesce(fragment("length(?)", m.to), 0),
            cc_size: coalesce(fragment("length(?)", m.cc), 0),
            bcc_size: coalesce(fragment("length(?)", m.bcc), 0),
            attachments: m.attachments
          })
          |> Repo.all()

        result =
          Enum.reduce(messages, 0, fn row, acc ->
            # Calculate attachment sizes from JSON metadata (includes S3 files)
            attachment_size = calculate_attachments_size(row.attachments)

            acc + row.text_size + row.html_size + row.subject_size +
              row.from_size + row.to_size + row.cc_size + row.bcc_size +
              attachment_size
          end)

        result
    end
  end

  # Calculate total size of attachments from the attachments JSON
  defp calculate_attachments_size(nil), do: 0

  defp calculate_attachments_size(attachments) when is_map(attachments) do
    attachments
    |> Map.values()
    |> Enum.reduce(0, fn attachment, acc ->
      # Get size from attachment metadata (works for both S3 and DB storage)
      size = Map.get(attachment, "size", 0)
      size_int = if is_integer(size), do: size, else: 0
      acc + size_int
    end)
  end

  defp calculate_attachments_size(_), do: 0

  def calculate_chat_storage(user_id) do
    # Get all messages with media from the user (exclude deleted)
    messages =
      Repo.all(
        from(m in Elektrine.Messaging.Message,
          where:
            m.sender_id == ^user_id and fragment("cardinality(?) > 0", m.media_urls) and
              is_nil(m.deleted_at),
          select: %{media_urls: m.media_urls, media_metadata: m.media_metadata}
        )
      )

    # Calculate total size from metadata (excluding Giphy URLs)
    Enum.reduce(messages, 0, fn message, acc ->
      metadata = message.media_metadata || %{}

      # Sum sizes from metadata for all URLs in this message (exclude Giphy)
      message_size =
        message.media_urls
        |> Enum.reject(&String.contains?(&1, "giphy.com"))
        |> Enum.reduce(0, fn url, url_acc ->
          case Map.get(metadata, url) do
            %{"size" => size} when is_integer(size) -> url_acc + size
            %{size: size} when is_integer(size) -> url_acc + size
            _ -> url_acc
          end
        end)

      acc + message_size
    end)
  end

  def calculate_profile_storage(user_id) do
    # Get user avatar size from users table
    user_avatar_size =
      case Repo.one(
             from(u in User,
               where: u.id == ^user_id,
               select: u.avatar_size
             )
           ) do
        nil -> 0
        size when is_integer(size) -> size
        _ -> 0
      end

    # Get profile image sizes from user_profiles table
    profile_sizes =
      case Repo.one(
             from(p in Elektrine.Profiles.UserProfile,
               where: p.user_id == ^user_id,
               select: %{
                 avatar: p.avatar_size,
                 banner: p.banner_size,
                 background: p.background_size
               }
             )
           ) do
        nil ->
          0

        data ->
          avatar_size = if is_integer(data.avatar), do: data.avatar, else: 0
          banner_size = if is_integer(data.banner), do: data.banner, else: 0
          background_size = if is_integer(data.background), do: data.background, else: 0
          avatar_size + banner_size + background_size
      end

    user_avatar_size + profile_sizes
  end

  def calculate_static_site_storage(user_id) do
    Elektrine.StaticSites.total_storage_used(user_id)
  end

  @doc """
  Formats bytes in human readable format (public for mix tasks).
  """
  def format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1024 * 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"
      bytes >= 1024 * 1024 -> "#{Float.round(bytes / (1024 * 1024), 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_bytes(_), do: "0 B"
end
