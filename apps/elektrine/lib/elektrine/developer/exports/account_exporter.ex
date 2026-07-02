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
  alias Elektrine.Accounts.User
  alias Elektrine.Accounts.UserMute
  alias Elektrine.ActivityPub
  alias Elektrine.ActivityPub.Actor
  alias Elektrine.ActivityPub.UserBlock, as: ActivityPubUserBlock
  alias Elektrine.Domains
  alias Elektrine.EmailAddresses
  alias Elektrine.OwnRoot
  alias Elektrine.Profiles
  alias Elektrine.Profiles.Follow
  alias Elektrine.Repo

  @doc """
  Exports account data for a user.

  Returns `{:ok, item_count}` on success.
  """
  def export(user_id, file_path, format, _filters \\ %{}) do
    user = Repo.get!(User, user_id)
    contacts = fetch_contacts(user_id)
    blocked = fetch_blocked_users(user_id)
    muted = fetch_muted_users(user_id)
    remote_following = fetch_remote_following(user_id)
    remote_blocks = fetch_remote_relationships(user_id, "user")
    remote_mutes = fetch_remote_relationships(user_id, "mute")
    domain_blocks = fetch_domain_blocks(user_id)

    relationships =
      format_relationships(%{
        contacts: contacts,
        blocked: blocked,
        muted: muted,
        remote_following: remote_following,
        remote_blocks: remote_blocks,
        remote_mutes: remote_mutes,
        domain_blocks: domain_blocks
      })

    data = %{
      profile: format_profile(user),
      own_root: format_own_root(user),
      settings: format_settings(user),
      privacy: format_privacy(user),
      notifications: format_notifications(user),
      contacts: Enum.map(contacts, &format_contact/1),
      blocked_users: Enum.map(blocked, &format_blocked/1),
      muted_users: Enum.map(muted, &format_muted/1),
      relationships: relationships,
      exported_at: DateTime.utc_now()
    }

    case format do
      "json" -> export_json(data, file_path)
      _ -> export_json(data, file_path)
    end

    relationship_count =
      length(contacts) + length(blocked) + length(muted) + length(remote_following) +
        length(remote_blocks) + length(remote_mutes) + length(domain_blocks)

    # Count: 1 for the account itself + exported relationship rows.
    {:ok, 1 + relationship_count}
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

  defp fetch_muted_users(user_id) do
    from(m in UserMute,
      where: m.muter_id == ^user_id,
      where: is_nil(m.expires_at) or m.expires_at > ^Elektrine.Time.utc_now(),
      join: u in User,
      on: u.id == m.muted_id,
      select: %{
        user: u,
        muted_at: m.inserted_at,
        mute_notifications: m.mute_notifications,
        expires_at: m.expires_at
      }
    )
    |> Repo.all()
  end

  defp fetch_remote_following(user_id) do
    from(f in Follow,
      where: f.follower_id == ^user_id and not is_nil(f.remote_actor_id),
      join: a in Actor,
      on: a.id == f.remote_actor_id,
      select: %{actor: a, followed_at: f.inserted_at, pending: f.pending}
    )
    |> Repo.all()
  end

  defp fetch_remote_relationships(user_id, block_type) do
    from(b in ActivityPubUserBlock,
      where: b.user_id == ^user_id and b.block_type == ^block_type,
      left_join: a in Actor,
      on: a.uri == b.blocked_uri,
      select: %{actor: a, uri: b.blocked_uri, inserted_at: b.inserted_at}
    )
    |> Repo.all()
  end

  defp fetch_domain_blocks(user_id) do
    from(b in ActivityPubUserBlock,
      where: b.user_id == ^user_id and b.block_type == "domain",
      select: %{domain: b.blocked_uri, blocked_at: b.inserted_at}
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
          escape_csv(EmailAddresses.primary_for_user(user) || ""),
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

  defp format_own_root(user) do
    built_in_domain = "#{user.handle || user.username}.#{Domains.default_profile_domain()}"
    verified_profile_domains = Profiles.verified_domains_for_user(user)
    per_site_identities = Profiles.list_user_per_site_identities(user)
    provider_base_url = Domains.public_base_url()

    domains =
      [%{domain: built_in_domain, status: "built_in", dns_records: []}]
      |> Enum.concat(
        Enum.map(verified_profile_domains, fn custom_domain ->
          %{
            domain: custom_domain.domain,
            status: custom_domain.status,
            dns_records: Profiles.dns_records_for_custom_domain(custom_domain)
          }
        end)
      )

    %{
      provider: provider_base_url,
      portable_root: "dns",
      domains:
        Enum.map(domains, fn %{domain: domain, status: status, dns_records: dns_records} ->
          %{
            domain: domain,
            status: status,
            subject: OwnRoot.subject(domain),
            did: OwnRoot.did_for_domain(domain),
            own_root:
              OwnRoot.document(user, domain,
                provider_base_url: provider_base_url,
                per_site_identities: per_site_identities
              ),
            did_document:
              OwnRoot.did_document(user, domain, provider_base_url: provider_base_url),
            activitypub_actor: "https://#{domain}/users/#{user.handle || user.username}",
            email_address: "#{user.username}@#{domain}",
            dns_records: dns_records,
            migration: %{
              own_root: "Serve this JSON at https://#{domain}/.well-known/own-root",
              did: "Serve this JSON at https://#{domain}/.well-known/did.json",
              oidc: "Update the OwnRoot document's OIDC issuer to the new provider.",
              activitypub:
                "Keep the ActivityPub actor URL stable or publish a Move activity from the old actor."
            }
          }
        end)
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
      default_post_visibility: user.default_post_visibility,
      hide_followers: user.hide_followers,
      hide_follows: user.hide_follows,
      hide_favorites: user.hide_favorites
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
      notify_on_comment: user.notify_on_comment,
      block_notifications_from_strangers: user.block_notifications_from_strangers,
      hide_notification_contents: user.hide_notification_contents
    }
  end

  defp format_contact(contact) do
    user = contact.user

    %{
      type: "local",
      user_id: user.id,
      username: user.username,
      account: local_account_address(user),
      handle: user.handle,
      display_name: user.display_name,
      avatar: user.avatar,
      followed_at: contact.followed_at
    }
  end

  defp format_blocked(blocked) do
    user = blocked.user

    %{
      type: "local",
      user_id: user.id,
      username: user.username,
      account: local_account_address(user),
      blocked_at: blocked.blocked_at
    }
  end

  defp format_muted(muted) do
    user = muted.user

    %{
      type: "local",
      user_id: user.id,
      username: user.username,
      account: local_account_address(user),
      muted_at: muted.muted_at,
      mute_notifications: muted.mute_notifications,
      expires_at: muted.expires_at
    }
  end

  defp format_relationships(relationships) do
    local_following = Enum.map(relationships.contacts, &format_contact/1)
    local_blocks = Enum.map(relationships.blocked, &format_blocked/1)
    local_mutes = Enum.map(relationships.muted, &format_muted/1)
    remote_following = Enum.map(relationships.remote_following, &format_remote_follow/1)
    remote_blocks = Enum.map(relationships.remote_blocks, &format_remote_block/1)
    remote_mutes = Enum.map(relationships.remote_mutes, &format_remote_mute/1)

    %{
      following: local_following ++ remote_following,
      blocks: local_blocks ++ remote_blocks,
      mutes: local_mutes ++ remote_mutes,
      domain_blocks: Enum.map(relationships.domain_blocks, &format_domain_block/1),
      import_lists: %{
        follows: Enum.map(local_following ++ remote_following, & &1.account),
        blocks: Enum.map(local_blocks ++ remote_blocks, & &1.account),
        mutes: Enum.map(local_mutes ++ remote_mutes, & &1.account),
        domain_blocks: Enum.map(relationships.domain_blocks, & &1.domain)
      }
    }
  end

  defp format_remote_follow(%{actor: actor, followed_at: followed_at, pending: pending}) do
    actor
    |> format_remote_actor()
    |> Map.merge(%{
      type: "remote",
      followed_at: followed_at,
      pending: pending
    })
  end

  defp format_remote_block(%{actor: actor, uri: uri, inserted_at: blocked_at}) do
    actor
    |> format_remote_actor(uri)
    |> Map.merge(%{type: "remote", blocked_at: blocked_at})
  end

  defp format_remote_mute(%{actor: actor, uri: uri, inserted_at: muted_at}) do
    actor
    |> format_remote_actor(uri)
    |> Map.merge(%{type: "remote", muted_at: muted_at})
  end

  defp format_domain_block(domain_block) do
    %{domain: domain_block.domain, blocked_at: domain_block.blocked_at}
  end

  defp format_remote_actor(actor, fallback_uri \\ nil)

  defp format_remote_actor(%Actor{} = actor, _fallback_uri) do
    %{
      account: remote_account_address(actor),
      uri: actor.uri,
      username: actor.username,
      domain: actor.domain,
      display_name: actor.display_name
    }
  end

  defp format_remote_actor(nil, fallback_uri) do
    %{account: fallback_uri, uri: fallback_uri, username: nil, domain: nil, display_name: nil}
  end

  defp local_account_address(%User{} = user) do
    "#{user.handle || user.username}@#{ActivityPub.instance_domain()}"
  end

  defp remote_account_address(%Actor{username: username, domain: domain})
       when is_binary(username) and is_binary(domain) do
    "#{username}@#{domain}"
  end

  defp remote_account_address(%Actor{uri: uri}), do: uri

  defp format_vcard(contact) do
    user = contact.user
    display_name = user.display_name || user.username

    """
    BEGIN:VCARD
    VERSION:3.0
    FN:#{display_name}
    N:;#{display_name};;;
    NICKNAME:#{user.username}
    EMAIL:#{EmailAddresses.primary_for_user(user)}
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
    UID:#{EmailAddresses.uid(event.id)}
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
