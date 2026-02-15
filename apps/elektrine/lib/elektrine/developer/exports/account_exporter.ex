defmodule Elektrine.Developer.Exports.AccountExporter do
  @moduledoc """
  Exports user's account data including profile, settings, and preferences.

  This module also handles contacts and calendar exports.

  Supported formats:
  - json: JSON format (most complete)
  - csv: CSV format for contacts
  - vcf: vCard format for contacts
  - ical: iCal format for calendar
  """

  import Ecto.Query
  alias Elektrine.Repo
  alias Elektrine.Accounts.User

  @doc """
  Exports account data for a user.

  Returns `{:ok, item_count}` on success.
  """
  def export(user_id, file_path, format, _filters \\ %{}) do
    user = Repo.get!(User, user_id)
    contacts = fetch_contacts(user_id)
    blocked = fetch_blocked_users(user_id)

    data = %{
      profile: format_profile(user),
      settings: format_settings(user),
      privacy: format_privacy(user),
      notifications: format_notifications(user),
      contacts: Enum.map(contacts, &format_contact/1),
      blocked_users: Enum.map(blocked, &format_blocked/1),
      exported_at: DateTime.utc_now()
    }

    case format do
      "json" -> export_json(data, file_path)
      _ -> export_json(data, file_path)
    end

    # Count: 1 for the account itself + contacts + blocked
    {:ok, 1 + length(contacts) + length(blocked)}
  end

  @doc """
  Exports contacts for a user.

  Returns `{:ok, item_count}` on success.
  """
  def export_contacts(user_id, file_path, format, _filters \\ %{}) do
    contacts = fetch_contacts(user_id)

    case format do
      "json" -> export_json(%{contacts: Enum.map(contacts, &format_contact/1)}, file_path)
      "vcf" -> export_vcf(contacts, file_path)
      "csv" -> export_contacts_csv(contacts, file_path)
      _ -> export_json(%{contacts: Enum.map(contacts, &format_contact/1)}, file_path)
    end

    {:ok, length(contacts)}
  end

  @doc """
  Exports calendar data for a user.

  Returns `{:ok, item_count}` on success.
  """
  def export_calendar(user_id, file_path, format, _filters \\ %{}) do
    events = fetch_calendar_events(user_id)

    case format do
      "json" -> export_json(%{events: Enum.map(events, &format_event/1)}, file_path)
      "ical" -> export_ical(events, file_path)
      _ -> export_json(%{events: Enum.map(events, &format_event/1)}, file_path)
    end

    {:ok, length(events)}
  end

  # Fetch contacts (friends/connections)
  defp fetch_contacts(user_id) do
    # Get friends (people the user follows)
    from(f in Elektrine.Profiles.Follow,
      where: f.follower_id == ^user_id,
      join: u in User,
      on: u.id == f.followed_id,
      select: %{
        user: u,
        followed_at: f.inserted_at
      }
    )
    |> Repo.all()
  end

  defp fetch_blocked_users(user_id) do
    from(b in Elektrine.Accounts.UserBlock,
      where: b.blocker_id == ^user_id,
      join: u in User,
      on: u.id == b.blocked_id,
      select: %{user: u, blocked_at: b.inserted_at}
    )
    |> Repo.all()
  end

  defp fetch_calendar_events(user_id) do
    case Code.ensure_loaded(Elektrine.Calendar.Event) do
      {:module, _} ->
        from(e in Elektrine.Calendar.Event,
          where: e.user_id == ^user_id,
          order_by: [desc: e.start_at]
        )
        |> Repo.all()

      _ ->
        []
    end
  end

  defp export_json(data, file_path) do
    json = Jason.encode!(data, pretty: true)
    File.write!(file_path, json)
  end

  defp export_vcf(contacts, file_path) do
    vcf_content =
      contacts
      |> Enum.map_join("\n", &format_vcard/1)

    File.write!(file_path, vcf_content)
  end

  defp export_contacts_csv(contacts, file_path) do
    headers = ["username", "handle", "display_name", "email", "followed_at"]
    header_row = Enum.join(headers, ",")

    rows =
      contacts
      |> Enum.map(fn contact ->
        user = contact.user

        [
          escape_csv(user.username || ""),
          escape_csv(user.handle || ""),
          escape_csv(user.display_name || ""),
          escape_csv("#{user.username}@elektrine.com"),
          to_string(contact.followed_at)
        ]
        |> Enum.join(",")
      end)

    content = [header_row | rows] |> Enum.join("\n")
    File.write!(file_path, content)
  end

  defp export_ical(events, file_path) do
    ical_content = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Elektrine//Data Export//EN
    #{Enum.map_join(events, "\n", &format_vevent/1)}
    END:VCALENDAR
    """

    File.write!(file_path, ical_content)
  end

  defp format_profile(user) do
    %{
      id: user.id,
      username: user.username,
      handle: user.handle,
      display_name: user.display_name,
      unique_id: user.unique_id,
      avatar: user.avatar,
      verified: user.verified,
      is_admin: user.is_admin,
      trust_level: user.trust_level,
      status: user.status,
      status_message: user.status_message,
      locale: user.locale,
      timezone: user.timezone,
      created_at: user.inserted_at
    }
  end

  defp format_settings(user) do
    %{
      locale: user.locale,
      timezone: user.timezone,
      time_format: user.time_format,
      preferred_email_domain: user.preferred_email_domain,
      email_signature: user.email_signature,
      two_factor_enabled: user.two_factor_enabled
    }
  end

  defp format_privacy(user) do
    %{
      allow_group_adds_from: user.allow_group_adds_from,
      allow_direct_messages_from: user.allow_direct_messages_from,
      allow_mentions_from: user.allow_mentions_from,
      allow_calls_from: user.allow_calls_from,
      allow_friend_requests_from: user.allow_friend_requests_from,
      profile_visibility: user.profile_visibility,
      default_post_visibility: user.default_post_visibility
    }
  end

  defp format_notifications(user) do
    %{
      notify_on_new_follower: user.notify_on_new_follower,
      notify_on_direct_message: user.notify_on_direct_message,
      notify_on_mention: user.notify_on_mention,
      notify_on_reply: user.notify_on_reply,
      notify_on_like: user.notify_on_like,
      notify_on_email_received: user.notify_on_email_received,
      notify_on_discussion_reply: user.notify_on_discussion_reply,
      notify_on_comment: user.notify_on_comment
    }
  end

  defp format_contact(contact) do
    user = contact.user

    %{
      user_id: user.id,
      username: user.username,
      handle: user.handle,
      display_name: user.display_name,
      avatar: user.avatar,
      followed_at: contact.followed_at
    }
  end

  defp format_blocked(blocked) do
    user = blocked.user

    %{
      user_id: user.id,
      username: user.username,
      blocked_at: blocked.blocked_at
    }
  end

  defp format_vcard(contact) do
    user = contact.user
    display_name = user.display_name || user.username

    """
    BEGIN:VCARD
    VERSION:3.0
    FN:#{display_name}
    N:;#{display_name};;;
    NICKNAME:#{user.username}
    EMAIL:#{user.username}@elektrine.com
    X-SOCIALPROFILE;TYPE=elektrine:#{user.handle}
    REV:#{DateTime.utc_now() |> DateTime.to_iso8601()}
    END:VCARD
    """
  end

  defp format_event(event) do
    %{
      id: event.id,
      title: event.title,
      description: event.description,
      start_at: event.start_at,
      end_at: event.end_at,
      location: event.location,
      all_day: event.all_day,
      created_at: event.inserted_at
    }
  end

  defp format_vevent(event) do
    start_dt = format_ical_datetime(event.start_at)
    end_dt = format_ical_datetime(event.end_at)

    """
    BEGIN:VEVENT
    UID:#{event.id}@elektrine.com
    DTSTART:#{start_dt}
    DTEND:#{end_dt}
    SUMMARY:#{escape_ical(event.title)}
    DESCRIPTION:#{escape_ical(event.description || "")}
    LOCATION:#{escape_ical(event.location || "")}
    END:VEVENT
    """
  end

  defp format_ical_datetime(nil), do: ""

  defp format_ical_datetime(datetime) do
    datetime
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601(:basic)
    |> String.replace("-", "")
    |> String.replace(":", "")
  end

  defp escape_csv(string) when is_binary(string) do
    if String.contains?(string, [",", "\"", "\n"]) do
      "\"" <> String.replace(string, "\"", "\"\"") <> "\""
    else
      string
    end
  end

  defp escape_csv(_), do: ""

  defp escape_ical(string) when is_binary(string) do
    string
    |> String.replace("\\", "\\\\")
    |> String.replace(",", "\\,")
    |> String.replace(";", "\\;")
    |> String.replace("\n", "\\n")
  end

  defp escape_ical(_), do: ""
end
