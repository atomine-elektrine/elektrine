# Script to seed a polished cross-platform account for product/demo screenshots.
# Run with:
#
#     mix run priv/repo/seed_platform_demo_screenshots.exs

import Ecto.Query

alias Elektrine.{
  Accounts,
  Calendar,
  Email,
  Messaging,
  Notifications,
  PasswordManager,
  Profiles,
  Repo,
  Social
}

alias Elektrine.Email.Message, as: EmailMessage
alias Elektrine.Messaging.{ChatMessage, Server}
alias Elektrine.Social.Conversation
alias Elektrine.Social.Message, as: SocialMessage
alias Elektrine.Notifications.Notification

seed_password = "DevPass123!"
screenshot_username = "platformdemo"

if Mix.env() == :dev do
  Code.require_file("seeds.exs", __DIR__)

  now = DateTime.utc_now() |> DateTime.truncate(:second)
  hours_ago = fn hours -> DateTime.add(now, -hours * 3_600, :second) end
  days_ago = fn days -> DateTime.add(now, -days * 86_400, :second) end
  hours_from_now = fn hours -> DateTime.add(now, hours * 3_600, :second) end
  days_from_now = fn days -> DateTime.add(now, days * 86_400, :second) end
  screenshot_message_id = fn key -> "platform-demo-#{key}@elektrine.dev" end

  ensure_seed_password = fn user ->
    case Accounts.admin_reset_password(user, %{password: seed_password}) do
      {:ok, updated_user} -> updated_user
      {:error, _reason} -> user
    end
  end

  ensure_user = fn username ->
    case Accounts.get_user_by_username(username) do
      nil ->
        case Accounts.create_user(%{
               username: username,
               password: seed_password,
               password_confirmation: seed_password
             }) do
          {:ok, user} ->
            ensure_seed_password.(user)

          {:error, reason} ->
            raise "Failed to create screenshot user #{username}: #{inspect(reason)}"
        end

      user ->
        ensure_seed_password.(user)
    end
  end

  ensure_mailbox = fn user ->
    case Email.get_user_mailbox(user.id) do
      nil ->
        case Email.ensure_user_has_mailbox(user) do
          {:ok, mailbox} -> mailbox
          mailbox -> mailbox
        end

      mailbox ->
        mailbox
    end
  end

  ensure_profile = fn user, attrs ->
    case Profiles.get_user_profile(user.id) do
      nil ->
        case Profiles.create_user_profile(user.id, attrs) do
          {:ok, profile} ->
            profile

          {:error, reason} ->
            raise "Failed to create profile for #{user.username}: #{inspect(reason)}"
        end

      profile ->
        case Profiles.update_user_profile(profile, attrs) do
          {:ok, updated_profile} ->
            updated_profile

          {:error, reason} ->
            raise "Failed to update profile for #{user.username}: #{inspect(reason)}"
        end
    end
  end

  ensure_profile_link = fn profile, attrs ->
    title = Map.fetch!(attrs, :title)

    case Repo.get_by(Profiles.ProfileLink, profile_id: profile.id, title: title) do
      nil ->
        case Profiles.create_profile_link(profile.id, attrs) do
          {:ok, link} -> link
          {:error, reason} -> raise "Failed to create profile link #{title}: #{inspect(reason)}"
        end

      link ->
        link
    end
  end

  ensure_follow = fn follower_id, followed_id ->
    case Repo.get_by(Profiles.Follow, follower_id: follower_id, followed_id: followed_id) do
      nil ->
        case Profiles.follow_user(follower_id, followed_id) do
          {:ok, _follow} ->
            :created

          {:error, :already_following} ->
            :existing

          {:error, reason} ->
            raise "Failed to follow #{follower_id} -> #{followed_id}: #{inspect(reason)}"
        end

      _follow ->
        :existing
    end
  end

  ensure_email = fn mailbox_id, attrs ->
    message_id = Map.fetch!(attrs, :message_id)
    mailbox = Email.Mailboxes.get_mailbox(mailbox_id)

    case Repo.get_by(EmailMessage, mailbox_id: mailbox_id, message_id: message_id) do
      nil ->
        case Email.create_message(attrs) do
          {:ok, message} -> message
          {:error, reason} -> raise "Failed to create email #{message_id}: #{inspect(reason)}"
        end

      %EmailMessage{} = message ->
        decrypted =
          case mailbox do
            %{user_id: user_id} when is_integer(user_id) ->
              EmailMessage.decrypt_content(message, user_id)

            _ ->
              message
          end

        if decrypted.text_body == "[Decryption failed]" or
             decrypted.html_body == "[Decryption failed]" do
          case Email.delete_message(message) do
            {:ok, _message} ->
              case Email.create_message(attrs) do
                {:ok, recreated_message} ->
                  recreated_message

                {:error, reason} ->
                  raise "Failed to recreate email #{message_id}: #{inspect(reason)}"
              end

            {:error, reason} ->
              raise "Failed to replace email #{message_id}: #{inspect(reason)}"
          end
        else
          message
        end
    end
  end

  ensure_label = fn user_id, attrs ->
    name = Map.fetch!(attrs, :name)

    case Email.get_label_by_name(name, user_id) do
      nil ->
        case Email.create_label(attrs) do
          {:ok, label} -> label
          {:error, reason} -> raise "Failed to create label #{name}: #{inspect(reason)}"
        end

      label ->
        label
    end
  end

  ensure_timeline_post = fn user_id, content, opts ->
    post_type = Keyword.get(opts, :post_type, "post")
    reply_to_id = Keyword.get(opts, :reply_to_id)

    existing_query =
      from(m in SocialMessage,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where:
          c.type == "timeline" and
            m.sender_id == ^user_id and
            m.post_type == ^post_type and
            m.content == ^content and
            is_nil(m.deleted_at),
        limit: 1
      )

    existing_query =
      if is_nil(reply_to_id) do
        from(m in existing_query, where: is_nil(m.reply_to_id))
      else
        from(m in existing_query, where: m.reply_to_id == ^reply_to_id)
      end

    case Repo.one(existing_query) do
      nil ->
        case Social.create_timeline_post(user_id, content, opts) do
          {:ok, post} -> post
          {:error, reason} -> raise "Failed to create timeline post: #{inspect(reason)}"
        end

      post ->
        post
    end
  end

  ensure_server = fn creator_id, attrs ->
    name = Map.fetch!(attrs, :name)

    case Repo.get_by(Server, creator_id: creator_id, name: name) do
      nil ->
        case Messaging.create_server(creator_id, attrs) do
          {:ok, server} -> server
          {:error, reason} -> raise "Failed to create server #{name}: #{inspect(reason)}"
        end

      server ->
        server
    end
  end

  ensure_server_member = fn server_id, user_id ->
    case Messaging.get_server_member(server_id, user_id) do
      nil ->
        case Messaging.join_server(server_id, user_id) do
          {:ok, _member} -> :created
          {:error, :already_joined} -> :existing
          {:error, reason} -> raise "Failed to join server #{server_id}: #{inspect(reason)}"
        end

      _member ->
        :existing
    end
  end

  ensure_server_channel = fn server_id, creator_id, attrs ->
    name = attrs |> Map.fetch!(:name) |> String.downcase()

    case Repo.get_by(Conversation, server_id: server_id, type: "channel", name: name) do
      nil ->
        case Messaging.create_server_channel(server_id, creator_id, attrs) do
          {:ok, channel} -> channel
          {:error, reason} -> raise "Failed to create channel #{name}: #{inspect(reason)}"
        end

      channel ->
        channel
    end
  end

  ensure_chat_message = fn conversation_id, sender_id, content ->
    case Repo.get_by(ChatMessage,
           conversation_id: conversation_id,
           sender_id: sender_id,
           content: content
         ) do
      nil ->
        case Messaging.create_text_message(conversation_id, sender_id, content, nil) do
          {:ok, message} -> message
          {:error, reason} -> raise "Failed to create chat message: #{inspect(reason)}"
        end

      message ->
        message
    end
  end

  ensure_calendar = fn user_id, attrs ->
    name = Map.fetch!(attrs, :name)

    case Calendar.get_calendar_by_name(user_id, name) do
      nil ->
        case Calendar.create_calendar(attrs) do
          {:ok, calendar} -> calendar
          {:error, reason} -> raise "Failed to create calendar #{name}: #{inspect(reason)}"
        end

      calendar ->
        calendar
    end
  end

  ensure_event = fn calendar_id, uid, attrs ->
    case Calendar.get_event_by_uid(calendar_id, uid) do
      nil ->
        case Calendar.create_event(Map.merge(attrs, %{calendar_id: calendar_id, uid: uid})) do
          {:ok, event} -> event
          {:error, reason} -> raise "Failed to create event #{uid}: #{inspect(reason)}"
        end

      event ->
        event
    end
  end

  ensure_notification = fn user_id, title, attrs ->
    case Repo.get_by(Notification, user_id: user_id, title: title) do
      nil ->
        case Notifications.create_notification(
               Map.merge(attrs, %{user_id: user_id, title: title})
             ) do
          {:ok, notification} -> notification
          {:error, reason} -> raise "Failed to create notification #{title}: #{inspect(reason)}"
        end

      notification ->
        notification
    end
  end

  seed_encrypted_payload = fn ciphertext ->
    %{
      "version" => 1,
      "algorithm" => "AES-GCM",
      "kdf" => "PBKDF2-SHA256",
      "iterations" => 150_000,
      "salt" => Base.encode64("platform-demo-salt"),
      "iv" => Base.encode64("demo-shot-iv"),
      "ciphertext" => Base.encode64(ciphertext)
    }
  end

  test_user =
    Accounts.get_user_by_username("testuser") || raise "Base seed user testuser is missing"

  orbitdev =
    Accounts.get_user_by_username("orbitdev") || raise "Base seed user orbitdev is missing"

  pixelvera =
    Accounts.get_user_by_username("pixelvera") || raise "Base seed user pixelvera is missing"

  opsnova = Accounts.get_user_by_username("opsnova") || raise "Base seed user opsnova is missing"

  local_mail_domain =
    case Email.get_user_mailbox(test_user.id) do
      %{email: email} ->
        case String.split(email, "@", parts: 2) do
          [_local, domain] when domain != "" -> domain
          _ -> Elektrine.Domains.primary_email_domain()
        end

      _ ->
        Elektrine.Domains.primary_email_domain()
    end

  screenshot_user = ensure_user.(screenshot_username)
  screenshot_mailbox = ensure_mailbox.(screenshot_user)

  profile =
    ensure_profile.(screenshot_user, %{
      display_name: "Platform Demo",
      description:
        "Curated cross-platform account for portal, inbox, chat, calendar, vault, and profile screenshots.",
      location: "Detroit, MI",
      theme: "blue",
      accent_color: "#38bdf8",
      background_color: "#0f172a",
      icon_color: "#38bdf8",
      font_family: "Trebuchet MS"
    })

  ensure_profile_link.(profile, %{
    title: "Platform Portal",
    url: "https://example.com/platformdemo",
    platform: "website",
    position: 0
  })

  ensure_profile_link.(profile, %{
    title: "Demo Inbox",
    url: "mailto:#{screenshot_username}@#{local_mail_domain}",
    platform: "email",
    position: 1
  })

  Enum.each(
    [
      {screenshot_user.id, orbitdev.id},
      {screenshot_user.id, pixelvera.id},
      {screenshot_user.id, opsnova.id},
      {orbitdev.id, screenshot_user.id},
      {pixelvera.id, screenshot_user.id}
    ],
    fn {follower_id, followed_id} -> ensure_follow.(follower_id, followed_id) end
  )

  launch_label =
    ensure_label.(screenshot_user.id, %{
      user_id: screenshot_user.id,
      name: "Launch",
      color: "#f59e0b"
    })

  launch_brief =
    ensure_email.(screenshot_mailbox.id, %{
      mailbox_id: screenshot_mailbox.id,
      message_id: screenshot_message_id.("launch-brief"),
      from: "orbitdev@#{local_mail_domain}",
      to: screenshot_mailbox.email,
      subject: "Launch brief is ready for the screenshot pass",
      text_body:
        "I folded the latest portal copy, timeline callouts, and vault notes into one short brief so the screenshots all tell the same story.",
      html_body:
        "<p>I folded the latest <strong>portal copy</strong>, timeline callouts, and vault notes into one short brief so the screenshots all tell the same story.</p>",
      category: "inbox",
      status: "received",
      priority: "high",
      read: false,
      flagged: true,
      inserted_at: hours_ago.(2),
      metadata: %{"sender_verified" => true}
    })

  mobile_pass =
    ensure_email.(screenshot_mailbox.id, %{
      mailbox_id: screenshot_mailbox.id,
      message_id: screenshot_message_id.("mobile-pass"),
      from: "pixelvera@#{local_mail_domain}",
      to: screenshot_mailbox.email,
      subject: "Mobile pass with attachment counts and copy tweaks",
      text_body:
        "Attached the revised mobile references. The stacked cards and hover states feel consistent now.",
      html_body:
        "<p>Attached the revised mobile references. The stacked cards and hover states feel consistent now.</p>",
      attachments: %{
        "1" => %{
          "filename" => "mobile-reference-board.png",
          "content_type" => "image/png",
          "size" => 184_322,
          "content_id" => "mobile-board@elektrine.dev"
        }
      },
      category: "inbox",
      status: "received",
      read: false,
      inserted_at: hours_ago.(6)
    })

  _boomerang_followup =
    ensure_email.(screenshot_mailbox.id, %{
      mailbox_id: screenshot_mailbox.id,
      message_id: screenshot_message_id.("boomerang-followup"),
      from: "opsnova@#{local_mail_domain}",
      to: screenshot_mailbox.email,
      subject: "Bring this back after the final launch checklist",
      text_body:
        "Parking this until tomorrow morning so the inbox shows an active boomerang state during capture.",
      html_body:
        "<p>Parking this until tomorrow morning so the inbox shows an active <strong>boomerang</strong> state during capture.</p>",
      category: "inbox",
      status: "received",
      read: true,
      reply_later_at: hours_from_now.(16),
      reply_later_reminder: true,
      inserted_at: hours_ago.(4)
    })

  _digest_email =
    ensure_email.(screenshot_mailbox.id, %{
      mailbox_id: screenshot_mailbox.id,
      message_id: screenshot_message_id.("digest-briefing"),
      from: "briefing@productsignals.dev",
      to: screenshot_mailbox.email,
      subject: "Weekly product briefing",
      text_body:
        "A compact roundup of launches, pricing changes, and design tools worth scanning before the next planning block.",
      html_body:
        "<p>A compact roundup of launches, pricing changes, and design tools worth scanning before the next planning block.</p>",
      category: "feed",
      status: "received",
      read: false,
      is_newsletter: true,
      inserted_at: days_ago.(1)
    })

  _ledger_email =
    ensure_email.(screenshot_mailbox.id, %{
      mailbox_id: screenshot_mailbox.id,
      message_id: screenshot_message_id.("ledger-invoice"),
      from: "billing@renderedcloud.dev",
      to: screenshot_mailbox.email,
      subject: "Invoice #8841 for March platform hosting",
      text_body: "Invoice total: $482.14. Auto-pay will process in three days.",
      html_body:
        "<p>Invoice total: <strong>$482.14</strong>. Auto-pay will process in three days.</p>",
      category: "ledger",
      status: "received",
      read: true,
      is_receipt: true,
      inserted_at: days_ago.(3)
    })

  :ok = Email.add_label_to_message(launch_brief.id, launch_label.id)
  :ok = Email.add_label_to_message(mobile_pass.id, launch_label.id)

  platform_post =
    ensure_timeline_post.(
      screenshot_user.id,
      "Platform demo account is ready for capture: portal, inbox, chat, calendar, and vault all share the same launch story now. #elektrine #product",
      visibility: "public"
    )

  _orbit_post =
    ensure_timeline_post.(
      orbitdev.id,
      "Trimmed the release notes so the portal card reads cleanly in a full-width screenshot. #shipping",
      visibility: "public"
    )

  _gallery_post =
    ensure_timeline_post.(
      pixelvera.id,
      "Saved a new editorial gallery card for the screenshot set so the timeline has richer visual variety. #design",
      visibility: "public",
      post_type: "gallery",
      category: "design"
    )

  _reply_post =
    ensure_timeline_post.(
      opsnova.id,
      "Replying here so the post detail view has a realistic follow-up thread during capture.",
      visibility: "public",
      reply_to_id: platform_post.id
    )

  unless Social.Likes.user_liked_post?(orbitdev.id, platform_post.id) do
    case Social.like_post(orbitdev.id, platform_post.id) do
      {:ok, _like} -> :ok
      {:error, :already_liked} -> :ok
      {:error, reason} -> raise "Failed to like platform post: #{inspect(reason)}"
    end
  end

  unless Social.Bookmarks.post_saved?(screenshot_user.id, platform_post.id) do
    case Social.save_post(screenshot_user.id, platform_post.id) do
      {:ok, _bookmark} -> :ok
      {:error, :already_saved} -> :ok
      {:error, reason} -> raise "Failed to bookmark platform post: #{inspect(reason)}"
    end
  end

  dm_with_orbit =
    case Messaging.create_dm_conversation(screenshot_user.id, orbitdev.id) do
      {:ok, conversation} -> conversation
      {:error, reason} -> raise "Failed to create screenshot DM: #{inspect(reason)}"
    end

  screenshot_server =
    ensure_server.(screenshot_user.id, %{
      name: "Platform Studio",
      description: "Public demo server with launch, design, and screenshot chatter.",
      is_public: true
    })

  Enum.each([orbitdev.id, pixelvera.id, opsnova.id], fn user_id ->
    ensure_server_member.(screenshot_server.id, user_id)
  end)

  captures_channel =
    ensure_server_channel.(screenshot_server.id, screenshot_user.id, %{
      name: "captures",
      description: "Final crop notes and screenshot shot list."
    })

  announcements_channel =
    ensure_server_channel.(screenshot_server.id, screenshot_user.id, %{
      name: "announcements",
      description: "Launch notes and cross-platform status updates."
    })

  ensure_chat_message.(
    dm_with_orbit.id,
    orbitdev.id,
    "Do one more pass on the portal screenshot before we lock the set."
  )

  ensure_chat_message.(
    dm_with_orbit.id,
    screenshot_user.id,
    "Looks good. Inbox and timeline now match the launch copy."
  )

  ensure_chat_message.(
    captures_channel.id,
    screenshot_user.id,
    "Collecting the final crops here so the demo pass has one clean thread."
  )

  ensure_chat_message.(
    captures_channel.id,
    pixelvera.id,
    "Mobile email and portal are the strongest shots right now."
  )

  ensure_chat_message.(
    announcements_channel.id,
    opsnova.id,
    "Vault, notifications, and calendar all have seeded data for capture."
  )

  work_calendar =
    ensure_calendar.(screenshot_user.id, %{
      user_id: screenshot_user.id,
      name: "Demo Work",
      color: "#38bdf8",
      description: "Launch reviews, recording blocks, and ship-room check-ins.",
      timezone: "America/Detroit",
      order: 1
    })

  personal_calendar =
    ensure_calendar.(screenshot_user.id, %{
      user_id: screenshot_user.id,
      name: "Demo Personal",
      color: "#22c55e",
      description: "Travel and after-hours blocks so the calendar feels lived in.",
      timezone: "America/Detroit",
      order: 2
    })

  _review_event =
    ensure_event.(work_calendar.id, "platform-demo-review@elektrine.dev", %{
      summary: "Screenshot review",
      description:
        "Walk through portal, email, and chat captures before publishing the demo set.",
      location: "War Room",
      dtstart: hours_from_now.(20),
      dtend: hours_from_now.(21),
      timezone: "America/Detroit",
      attendees: [
        %{"email" => "orbitdev@#{local_mail_domain}", "name" => "Orbit Dev"},
        %{"email" => "pixelvera@#{local_mail_domain}", "name" => "Pixel Vera"}
      ],
      categories: ["screenshots", "review"]
    })

  _launch_event =
    ensure_event.(work_calendar.id, "platform-demo-launch@elektrine.dev", %{
      summary: "Demo launch dry run",
      description: "Final pass across the platform before recording and image export.",
      location: "Studio B",
      dtstart: days_from_now.(2),
      dtend: DateTime.add(days_from_now.(2), 5_400, :second),
      timezone: "America/Detroit",
      categories: ["launch"]
    })

  _personal_event =
    ensure_event.(personal_calendar.id, "platform-demo-travel@elektrine.dev", %{
      summary: "Train to Chicago",
      description: "Keeps the personal calendar populated for screenshots.",
      location: "Detroit Station",
      dtstart: days_from_now.(3),
      dtend: DateTime.add(days_from_now.(3), 7_200, :second),
      timezone: "America/Detroit",
      categories: ["travel"]
    })

  unless PasswordManager.vault_configured?(screenshot_user.id) do
    case PasswordManager.setup_vault(screenshot_user.id, %{
           encrypted_verifier: seed_encrypted_payload.("platform-demo-vault-verifier")
         }) do
      {:ok, _settings} -> :ok
      {:error, reason} -> raise "Failed to set up screenshot vault: #{inspect(reason)}"
    end
  end

  Enum.each(
    [
      %{
        title: "Figma",
        login_username: "platformdemo@#{local_mail_domain}",
        website: "https://figma.com",
        encrypted_password: seed_encrypted_payload.("figma-demo-password"),
        encrypted_notes: seed_encrypted_payload.("Shared with Pixel Vera for mobile review")
      },
      %{
        title: "Docker",
        login_username: "platform-ops@#{local_mail_domain}",
        website: "https://docker.com",
        encrypted_password: seed_encrypted_payload.("docker-demo-password"),
        encrypted_notes:
          seed_encrypted_payload.("Check container health after the screenshot deploy")
      },
      %{
        title: "PostHog",
        login_username: "alerts@#{local_mail_domain}",
        website: "https://posthog.com",
        encrypted_password: seed_encrypted_payload.("posthog-demo-password"),
        encrypted_notes: seed_encrypted_payload.("Use this for the demo product event capture")
      }
    ],
    fn entry_attrs ->
      case Repo.get_by(PasswordManager.VaultEntry,
             user_id: screenshot_user.id,
             title: entry_attrs.title
           ) do
        nil ->
          case PasswordManager.create_entry(screenshot_user.id, entry_attrs) do
            {:ok, _entry} ->
              :ok

            {:error, reason} ->
              raise "Failed to create vault entry #{entry_attrs.title}: #{inspect(reason)}"
          end

        _entry ->
          :ok
      end
    end
  )

  ensure_notification.(screenshot_user.id, "@orbitdev started following you", %{
    type: "follow",
    body: nil,
    url: "/orbitdev",
    icon: "hero-user-plus",
    actor_id: orbitdev.id,
    source_type: "user",
    source_id: orbitdev.id,
    priority: "normal"
  })

  ensure_notification.(screenshot_user.id, "@pixelvera mentioned the demo pass", %{
    type: "mention",
    body: "The timeline and inbox now share the same visual direction.",
    url: "/timeline/post/#{platform_post.id}",
    icon: "hero-at-symbol",
    actor_id: pixelvera.id,
    source_type: "post",
    source_id: platform_post.id,
    priority: "high"
  })

  ensure_notification.(screenshot_user.id, "@opsnova replied to your platform post", %{
    type: "reply",
    body: "The threaded detail view is ready for capture.",
    url: "/timeline/post/#{platform_post.id}",
    icon: "hero-chat-bubble-left",
    actor_id: opsnova.id,
    source_type: "post",
    source_id: platform_post.id,
    priority: "normal"
  })

  ensure_notification.(screenshot_user.id, "Screenshot seed refreshed", %{
    type: "system",
    body: "Portal, inbox, chat, calendar, notifications, and vault now have curated demo data.",
    url: "/portal",
    icon: "hero-sparkles",
    source_type: "system",
    source_id: screenshot_user.id,
    priority: "high"
  })

  dm_identifier = dm_with_orbit.hash || dm_with_orbit.id
  captures_identifier = captures_channel.hash || captures_channel.id
  launch_brief_identifier = launch_brief.hash || launch_brief.id

  IO.puts("")
  IO.puts("✓ Platform demo screenshot seed is ready")
  IO.puts("  Account: #{screenshot_username}")
  IO.puts("  Email: #{screenshot_mailbox.email}")
  IO.puts("  Password: #{seed_password}")
  IO.puts("")
  IO.puts("Suggested routes:")
  IO.puts("  /portal")
  IO.puts("  /email?tab=inbox&filter=unread")
  IO.puts("  /email?tab=inbox&filter=boomerang")
  IO.puts("  /email?tab=inbox&filter=digest")
  IO.puts("  /email?tab=inbox&filter=ledger")
  IO.puts("  /email/view/#{launch_brief_identifier}")
  IO.puts("  /timeline")
  IO.puts("  /timeline/post/#{platform_post.id}")
  IO.puts("  /chat/#{dm_identifier}")
  IO.puts("  /chat/#{captures_identifier}")
  IO.puts("  /calendar")
  IO.puts("  /notifications")
  IO.puts("  /account/password-manager  # Vault")
  IO.puts("  /#{screenshot_username}")
else
  IO.puts("Skipping screenshot seed - not in development environment")
end
