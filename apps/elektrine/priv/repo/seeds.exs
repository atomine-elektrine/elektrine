# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Elektrine.Repo.insert!(%Elektrine.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

alias Elektrine.{Accounts, Calendar, Email, Messaging, PasswordManager, Profiles, Repo, Social}
alias Elektrine.Email.Contacts
import Ecto.Query

# Only run in development environment
if Mix.env() == :dev do
  IO.puts("Seeding development data...")

  admin_password = "DevPass123!"
  test_password = "DevPass123!"

  ensure_admin_user = fn user, username ->
    admin_user =
      if user.is_admin do
        user
      else
        {:ok, updated_user} = Accounts.update_user_admin_status(user, true)
        IO.puts("✓ Made existing user '#{username}' an admin")
        updated_user
      end

    case Accounts.admin_reset_password(admin_user, %{password: admin_password}) do
      {:ok, updated_user} ->
        IO.puts("✓ Set seed password for '#{username}'")
        updated_user

      {:error, password_error} ->
        IO.puts("✗ Failed to set seed password for '#{username}': #{inspect(password_error)}")
        admin_user
    end
  end

  ensure_test_password = fn user ->
    case Accounts.admin_reset_password(user, %{password: test_password}) do
      {:ok, updated_user} ->
        IO.puts("✓ Set seed password for 'testuser'")
        updated_user

      {:error, password_error} ->
        IO.puts("✗ Failed to set seed password for 'testuser': #{inspect(password_error)}")
        user
    end
  end

  # Create admin user if it doesn't exist
  admin_username = "admin"

  admin_user =
    case Accounts.get_user_by_username(admin_username) do
      nil ->
        IO.puts("Creating admin user: #{admin_username}")

        case Accounts.create_user(%{
               username: admin_username,
               password: admin_password,
               password_confirmation: admin_password
             }) do
          {:ok, admin_user} ->
            # Make the user an admin
            {:ok, admin_user} = Accounts.update_user_admin_status(admin_user, true)

            IO.puts("✓ Admin user created with username: #{admin_username}")

            admin_user

          {:error, %Ecto.Changeset{errors: errors}} ->
            IO.puts("✗ Failed to create admin user: #{inspect(errors)}")
            IO.puts("  This might be because 'admin' conflicts with an existing alias.")
            IO.puts("  Using alternative username 'sysadmin' instead...")

            fallback_username = "sysadmin"

            case Accounts.get_user_by_username(fallback_username) do
              nil ->
                case Accounts.create_user(%{
                       username: fallback_username,
                       password: admin_password,
                       password_confirmation: admin_password
                     }) do
                  {:ok, fallback_user} ->
                    fallback_user = ensure_admin_user.(fallback_user, fallback_username)
                    IO.puts("✓ Admin user created with username: #{fallback_username}")
                    fallback_user

                  {:error, fallback_errors} ->
                    IO.puts("✗ Failed to create fallback admin user: #{inspect(fallback_errors)}")
                    # Return nil and handle this case below
                    nil
                end

              existing_fallback_user ->
                IO.puts("✓ Fallback admin user '#{fallback_username}' already exists")
                ensure_admin_user.(existing_fallback_user, fallback_username)
            end
        end

      existing_user ->
        IO.puts("✓ Admin user '#{admin_username}' already exists")
        ensure_admin_user.(existing_user, admin_username)
    end

  # Create a test user if it doesn't exist
  test_username = "testuser"

  test_user =
    case Accounts.get_user_by_username(test_username) do
      nil ->
        IO.puts("Creating test user: #{test_username}")

        {:ok, test_user} =
          Accounts.create_user(%{
            username: test_username,
            password: test_password,
            password_confirmation: test_password
          })

        IO.puts("✓ Test user created with username: #{test_username}")
        test_user

      existing_user ->
        IO.puts("✓ Test user '#{test_username}' already exists")
        ensure_test_password.(existing_user)
    end

  preferred_mailbox_email = fn user ->
    available_domains = Elektrine.Domains.available_email_domains_for_user(user.id)
    preferred_domain = String.trim(user.preferred_email_domain || "")

    mailbox_domain =
      if preferred_domain != "" and preferred_domain in available_domains do
        preferred_domain
      else
        List.first(available_domains) || Elektrine.Domains.default_user_handle_domain()
      end

    "#{user.username}@#{mailbox_domain}"
  end

  ensure_local_mailbox = fn user ->
    expected_email = preferred_mailbox_email.(user)

    case Enum.find(Email.list_mailboxes(user.id), &(&1.email == expected_email)) do
      %Email.Mailbox{} = mailbox ->
        {:ok, mailbox}

      nil ->
        Email.create_mailbox(%{email: expected_email, username: user.username, user_id: user.id})
    end
  end

  # Create mailboxes for both users if they don't exist
  admin_mailbox =
    if admin_user do
      case ensure_local_mailbox.(admin_user) do
        {:ok, mailbox} ->
          IO.puts("✓ Ensured admin mailbox: #{mailbox.email}")
          mailbox

        {:error, reason} ->
          raise "Failed to ensure admin mailbox for #{admin_user.username}: #{inspect(reason)}"
      end
    else
      IO.puts("✗ Skipping admin mailbox creation (no admin user)")
      nil
    end

  test_mailbox =
    case ensure_local_mailbox.(test_user) do
      {:ok, mailbox} ->
        IO.puts("✓ Ensured test mailbox: #{mailbox.email}")
        mailbox

      {:error, reason} ->
        raise "Failed to ensure test mailbox for #{test_user.username}: #{inspect(reason)}"
    end

  IO.puts("Seeding email coverage...")

  now = DateTime.utc_now() |> DateTime.truncate(:second)
  days_ago = fn days -> DateTime.add(now, -days * 86_400, :second) end
  hours_ago = fn hours -> DateTime.add(now, -hours * 3_600, :second) end
  days_from_now = fn days -> DateTime.add(now, days * 86_400, :second) end
  hours_from_now = fn hours -> DateTime.add(now, hours * 3_600, :second) end
  seed_message_id = fn seed_key -> "seed-#{seed_key}@elektrine.dev" end

  seed_message_decryption_failed? = fn
    %Email.Message{status: "draft"} ->
      false

    %Email.Message{mailbox_id: mailbox_id} = message ->
      case Email.Mailboxes.get_mailbox(mailbox_id) do
        %{user_id: user_id} when is_integer(user_id) ->
          decrypted = Email.Message.decrypt_content(message, user_id)

          decrypted.text_body == "[Decryption failed]" or
            decrypted.html_body == "[Decryption failed]"

        _ ->
          false
      end
  end

  {legacy_feed_updates, _} =
    from(m in Email.Message,
      where: m.mailbox_id == ^test_mailbox.id and m.category == "paper_pile"
    )
    |> Repo.update_all(set: [category: "feed"])

  if legacy_feed_updates > 0 do
    IO.puts("✓ Migrated #{legacy_feed_updates} legacy paper_pile messages to feed")
  end

  create_seed_message = fn attrs ->
    seed_key = Map.fetch!(attrs, :seed_key)
    attrs = Map.delete(attrs, :seed_key)
    inserted_at = Map.get(attrs, :inserted_at, hours_ago.(24))

    attrs =
      attrs
      |> Map.put_new(:message_id, seed_message_id.(seed_key))
      |> Map.put_new(:inserted_at, inserted_at)
      |> Map.put_new(:updated_at, inserted_at)

    mailbox_id = Map.fetch!(attrs, :mailbox_id)
    message_id = Map.fetch!(attrs, :message_id)

    insert_seed_message = fn ->
      case Map.get(attrs, :status) do
        "draft" ->
          attrs
          |> then(&Email.Message.changeset(%Email.Message{}, &1))
          |> Repo.insert!()

        _ ->
          case Email.create_message(attrs) do
            {:ok, _message} ->
              :ok

            {:error, reason} ->
              raise "Failed to create seed email #{message_id}: #{inspect(reason)}"
          end
      end
    end

    case Repo.get_by(Email.Message, mailbox_id: mailbox_id, message_id: message_id) do
      nil ->
        insert_seed_message.()

        :created

      %Email.Message{} = existing ->
        if seed_message_decryption_failed?.(existing) do
          case Email.delete_message(existing) do
            {:ok, _message} ->
              insert_seed_message.()
              :repaired

            {:error, reason} ->
              raise "Failed to replace undecryptable seed email #{message_id}: #{inspect(reason)}"
          end
        else
          :existing
        end
    end
  end

  launch_root_id = seed_message_id.("thread-launch-blockers-root")
  launch_reply_id = seed_message_id.("thread-launch-blockers-reply")

  inbox_emails = [
    %{
      seed_key: "inbox-planning-meeting",
      mailbox_id: test_mailbox.id,
      from: "sarah@company.com",
      to: "testuser@example.com",
      cc: "ops@company.com, design@agency.com",
      subject: "Q4 Planning Meeting Tomorrow",
      text_body:
        "Hi there,\n\nJust a reminder about our Q4 planning meeting tomorrow at 2 PM. Please bring your project updates and the revised launch timeline.\n\nBest,\nSarah",
      html_body:
        "<p>Hi there,</p><p>Just a reminder about our Q4 planning meeting tomorrow at <strong>2 PM</strong>. Please bring your project updates and the revised launch timeline.</p><p>Best,<br>Sarah</p>",
      category: "inbox",
      status: "received",
      priority: "high",
      read: false,
      inserted_at: hours_ago.(4),
      metadata: %{"sender_verified" => true, "meeting" => true}
    },
    %{
      seed_key: "inbox-contract-review",
      mailbox_id: test_mailbox.id,
      from: "john.doe@business.com",
      to: "testuser@example.com",
      subject: "Project Documents - Please Review",
      text_body: """
      Hi there,

      Please find the attached documents for your review:

      1. project-proposal.pdf
      2. mockup-design.png
      3. budget-breakdown.xlsx

      Let me know if you have any questions or need clarification on anything.

      Best regards,
      John Doe
      Senior Project Manager
      """,
      html_body: """
      <p>Hi there,</p>
      <p>Please find the attached documents for your review:</p>
      <ol>
        <li><strong>project-proposal.pdf</strong></li>
        <li><strong>mockup-design.png</strong></li>
        <li><strong>budget-breakdown.xlsx</strong></li>
      </ol>
      <p>Let me know if you have any questions or need clarification on anything.</p>
      <p>Best regards,<br><strong>John Doe</strong><br>Senior Project Manager</p>
      """,
      attachments: %{
        "1" => %{
          "filename" => "project-proposal.pdf",
          "content_type" => "application/pdf",
          "size" => 245_760,
          "content_id" => "attachment1@business.com"
        },
        "2" => %{
          "filename" => "mockup-design.png",
          "content_type" => "image/png",
          "size" => 89_432,
          "content_id" => "attachment2@business.com"
        },
        "3" => %{
          "filename" => "budget-breakdown.xlsx",
          "content_type" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
          "size" => 12_856,
          "content_id" => "attachment3@business.com"
        }
      },
      category: "inbox",
      status: "received",
      flagged: true,
      read: false,
      inserted_at: days_ago.(1),
      metadata: %{
        "attachment_count" => 3,
        "total_attachment_size" => 348_048,
        "sender_verified" => true
      }
    },
    %{
      seed_key: "thread-launch-blockers-root",
      mailbox_id: test_mailbox.id,
      from: "nina@company.com",
      to: "testuser@example.com",
      subject: "Q2 launch blockers before Thursday",
      text_body: """
      Hey,

      Before Thursday's review, can you send over:

      - the final risk register
      - the fallback plan for payments
      - the customer comms draft

      I only need rough bullets, not polished copy.

      Nina
      """,
      html_body: nil,
      category: "inbox",
      status: "received",
      read: true,
      answered: true,
      open_count: 2,
      first_opened_at: days_ago.(3),
      opened_at: days_ago.(2),
      inserted_at: days_ago.(3)
    },
    %{
      seed_key: "thread-launch-blockers-followup",
      mailbox_id: test_mailbox.id,
      from: "nina@company.com",
      to: "testuser@example.com",
      subject: "Re: Q2 launch blockers before Thursday",
      text_body:
        "Thanks. The customer comms outline is enough. Can you add one note on rollback ownership before tomorrow morning?",
      html_body:
        "<p>Thanks. The customer comms outline is enough. Can you add one note on rollback ownership before tomorrow morning?</p>",
      category: "inbox",
      status: "received",
      read: false,
      in_reply_to: launch_reply_id,
      inserted_at: hours_ago.(18)
    },
    %{
      seed_key: "inbox-plaintext-notes",
      mailbox_id: test_mailbox.id,
      from: "alice@example.com",
      to: "testuser@example.com",
      subject: "Simple plaintext message",
      text_body: """
      Hello! This is a simple plaintext email with no HTML formatting.

      It has multiple paragraphs and should display with proper line breaks.

      The mobile show view should still feel good with:
      - bullets
      - long lines that wrap cleanly
      - a signature block

      Best regards,
      Alice
      """,
      html_body: nil,
      category: "inbox",
      status: "received",
      read: false,
      inserted_at: hours_ago.(9)
    }
  ]

  digest_emails = [
    %{
      seed_key: "digest-tech-roundup",
      mailbox_id: test_mailbox.id,
      from: "newsletter@techblog.com",
      to: "testuser@example.com",
      subject: "Weekly Tech Digest - AI Breakthroughs & More",
      text_body:
        "This week in tech: new AI models, startup funding rounds, and the latest gadget reviews.",
      html_body: """
      <html>
      <body style="margin:0;padding:24px;background:#0f172a;font-family:Arial,sans-serif;">
        <table width="100%" cellpadding="0" cellspacing="0" border="0">
          <tr>
            <td align="center">
              <table width="620" cellpadding="0" cellspacing="0" border="0" style="background:#111827;border-radius:18px;overflow:hidden;">
                <tr>
                  <td style="padding:36px;background:linear-gradient(135deg,#1d4ed8,#06b6d4);color:#fff;">
                    <p style="margin:0;font-size:12px;letter-spacing:1.4px;text-transform:uppercase;">TechBlog Weekly</p>
                    <h1 style="margin:12px 0 8px;font-size:28px;">AI models, cloud spend, and the gadget cycle</h1>
                    <p style="margin:0;color:#dbeafe;">A compact issue with three stories worth forwarding.</p>
                  </td>
                </tr>
                <tr>
                  <td style="padding:28px;color:#d1d5db;">
                    <h2 style="margin:0 0 10px;color:#fff;font-size:20px;">Top Story</h2>
                    <p style="margin:0 0 18px;line-height:1.6;">Leading labs are shipping smaller models with better reasoning-per-dollar, which is already changing internal tooling budgets.</p>
                    <table width="100%" cellpadding="0" cellspacing="0" border="0">
                      <tr>
                        <td style="width:50%;padding-right:12px;vertical-align:top;">
                          <div style="background:#1f2937;border-radius:12px;padding:16px;">
                            <h3 style="margin:0 0 8px;color:#fff;font-size:16px;">Funding</h3>
                            <p style="margin:0;line-height:1.5;">Enterprise infra startup closes a large Series C round.</p>
                          </div>
                        </td>
                        <td style="width:50%;padding-left:12px;vertical-align:top;">
                          <div style="background:#1f2937;border-radius:12px;padding:16px;">
                            <h3 style="margin:0 0 8px;color:#fff;font-size:16px;">Review</h3>
                            <p style="margin:0;line-height:1.5;">A practical take on the newest flagship phone.</p>
                          </div>
                        </td>
                      </tr>
                    </table>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
        </table>
      </body>
      </html>
      """,
      category: "feed",
      status: "received",
      read: true,
      is_newsletter: true,
      open_count: 3,
      first_opened_at: days_ago.(6),
      opened_at: days_ago.(2),
      inserted_at: days_ago.(6)
    },
    %{
      seed_key: "digest-retail-sale",
      mailbox_id: test_mailbox.id,
      from: "deals@retailstore.com",
      to: "testuser@example.com",
      subject: "Weekend Sale - Up to 70% Off",
      text_body:
        "Don't miss our biggest sale of the month. Smart home gear, headphones, and travel accessories are all discounted.",
      html_body: """
      <html>
      <body style="margin:0;padding:24px;background:#f8fafc;font-family:Arial,sans-serif;">
        <div style="max-width:620px;margin:0 auto;background:#fff;border-radius:18px;overflow:hidden;border:1px solid #e2e8f0;">
          <div style="padding:36px;text-align:center;background:linear-gradient(135deg,#7c3aed,#ef4444);color:#fff;">
            <p style="margin:0 0 8px;font-size:13px;letter-spacing:1px;text-transform:uppercase;">RetailStore</p>
            <h1 style="margin:0;font-size:34px;">Weekend Sale</h1>
            <p style="margin:12px 0 0;font-size:18px;">Up to 70% off select gear</p>
          </div>
          <div style="padding:28px;">
            <p style="margin:0 0 18px;color:#334155;line-height:1.6;">Fast picks for people who waited until the last minute.</p>
            <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:12px;">
              <div style="background:#f8fafc;border-radius:12px;padding:14px;text-align:center;">Smart Watch<br><strong>$89</strong></div>
              <div style="background:#f8fafc;border-radius:12px;padding:14px;text-align:center;">Earbuds<br><strong>$44</strong></div>
              <div style="background:#f8fafc;border-radius:12px;padding:14px;text-align:center;">Carry-on<br><strong>$59</strong></div>
            </div>
          </div>
        </div>
      </body>
      </html>
      """,
      category: "feed",
      status: "received",
      read: false,
      is_newsletter: true,
      inserted_at: days_ago.(2)
    },
    %{
      seed_key: "digest-social-updates",
      mailbox_id: test_mailbox.id,
      from: "updates@socialmedia.com",
      to: "testuser@example.com",
      subject: "You have 5 new notifications",
      text_body:
        "Check out what's happening in your network. 3 likes, 1 comment, and 1 new follower.",
      html_body:
        "<p>Check out what's happening in your network. <strong>3 likes</strong>, <strong>1 comment</strong>, and <strong>1 new follower</strong>.</p>",
      category: "feed",
      status: "received",
      read: false,
      is_notification: true,
      inserted_at: hours_ago.(14)
    },
    %{
      seed_key: "digest-community-plaintext",
      mailbox_id: test_mailbox.id,
      from: "newsletter@community.org",
      to: "testuser@example.com",
      subject: "Weekly community update",
      text_body: """
      WEEKLY COMMUNITY NEWSLETTER
      ==========================

      - Tuesday: design systems meetup
      - Wednesday: Elixir office hours
      - Friday: shipping retrospective notes

      Featured link:
      https://community.example.com/notes

      Unsubscribe:
      https://community.example.com/unsubscribe
      """,
      html_body: nil,
      category: "feed",
      status: "received",
      read: true,
      is_newsletter: true,
      inserted_at: days_ago.(9)
    }
  ]

  ledger_emails = [
    %{
      seed_key: "ledger-bank-statement",
      mailbox_id: test_mailbox.id,
      from: "security@bank.com",
      to: "testuser@example.com",
      subject: "Your Account Statement is Ready",
      text_body:
        "Your monthly account statement is now available for download in your online banking portal.",
      html_body:
        "<p>Your monthly account statement is now available for download in your online banking portal.</p>",
      attachments: %{
        "1" => %{
          "filename" => "statement-september.pdf",
          "content_type" => "application/pdf",
          "size" => 432_188,
          "content_id" => "statement@bank.com"
        }
      },
      category: "ledger",
      status: "received",
      read: false,
      is_receipt: true,
      inserted_at: days_ago.(5)
    },
    %{
      seed_key: "ledger-cloud-invoice",
      mailbox_id: test_mailbox.id,
      from: "billing@cloudvendor.com",
      to: "testuser@example.com",
      subject: "Invoice #48291 for March",
      text_body:
        "Your March invoice is attached. Total due: $429.33. Auto-pay will run in 3 days.",
      html_body: """
      <html>
      <body style="font-family:Arial,sans-serif;background:#f8fafc;padding:24px;">
        <div style="max-width:620px;margin:0 auto;background:#fff;border:1px solid #e2e8f0;border-radius:16px;padding:28px;">
          <div style="display:flex;justify-content:space-between;align-items:flex-start;">
            <div>
              <p style="margin:0;color:#64748b;text-transform:uppercase;font-size:12px;">CloudVendor</p>
              <h1 style="margin:8px 0 0;font-size:28px;color:#0f172a;">Invoice #48291</h1>
            </div>
            <div style="text-align:right;">
              <p style="margin:0;color:#64748b;font-size:13px;">Amount due</p>
              <p style="margin:8px 0 0;font-size:26px;color:#0f172a;"><strong>$429.33</strong></p>
            </div>
          </div>
          <table width="100%" cellpadding="8" cellspacing="0" border="0" style="margin-top:24px;border-collapse:collapse;">
            <tr><td style="border-top:1px solid #e2e8f0;color:#334155;">Compute</td><td style="border-top:1px solid #e2e8f0;text-align:right;color:#334155;">$214.11</td></tr>
            <tr><td style="border-top:1px solid #e2e8f0;color:#334155;">Storage</td><td style="border-top:1px solid #e2e8f0;text-align:right;color:#334155;">$87.42</td></tr>
            <tr><td style="border-top:1px solid #e2e8f0;color:#334155;">Bandwidth</td><td style="border-top:1px solid #e2e8f0;text-align:right;color:#334155;">$127.80</td></tr>
          </table>
        </div>
      </body>
      </html>
      """,
      attachments: %{
        "1" => %{
          "filename" => "cloudvendor-invoice-48291.pdf",
          "content_type" => "application/pdf",
          "size" => 182_440,
          "content_id" => "invoice48291@cloudvendor.com"
        }
      },
      category: "ledger",
      status: "received",
      read: true,
      is_receipt: true,
      inserted_at: days_ago.(7),
      metadata: %{"vendor" => "CloudVendor", "auto_pay" => true}
    },
    %{
      seed_key: "ledger-flight-confirmation",
      mailbox_id: test_mailbox.id,
      from: "travel@airline.com",
      to: "testuser@example.com",
      subject: "Flight Confirmation - NYC to LA",
      text_body:
        "Your flight is confirmed. Flight AA123 on June 15th, departing at 8:00 AM from JFK.",
      html_body:
        "<p>Your flight is confirmed. <strong>Flight AA123</strong> on June 15th, departing at 8:00 AM from JFK.</p>",
      category: "ledger",
      status: "received",
      read: true,
      is_receipt: true,
      inserted_at: days_ago.(12)
    },
    %{
      seed_key: "ledger-domain-renewal",
      mailbox_id: test_mailbox.id,
      from: "receipts@registrar.com",
      to: "testuser@example.com",
      subject: "Receipt for domain renewal",
      text_body:
        "Your domain renewal for elektrine.dev has been processed successfully. Total charged: $18.99.",
      html_body:
        "<p>Your domain renewal for <strong>elektrine.dev</strong> has been processed successfully. Total charged: <strong>$18.99</strong>.</p>",
      category: "ledger",
      status: "received",
      read: false,
      is_receipt: true,
      inserted_at: hours_ago.(30)
    }
  ]

  stack_emails = [
    %{
      seed_key: "stack-design-feedback",
      mailbox_id: test_mailbox.id,
      from: "pm@client.org",
      to: "testuser@example.com",
      subject: "Need your eyes on the onboarding redesign",
      text_body:
        "Could you take a pass through the new onboarding flow when you have 20 minutes? The edge cases are in the attached notes.",
      html_body:
        "<p>Could you take a pass through the new onboarding flow when you have 20 minutes? The edge cases are in the attached notes.</p>",
      category: "stack",
      stack_at: days_ago.(2),
      stack_reason: "Waiting for stakeholder notes",
      status: "received",
      read: false,
      inserted_at: days_ago.(4)
    },
    %{
      seed_key: "stack-rfp-brief",
      mailbox_id: test_mailbox.id,
      from: "procurement@enterprise.com",
      to: "testuser@example.com",
      subject: "RFP response draft for review",
      text_body:
        "The draft RFP response is attached. I mainly need a gut check on scope, risk, and where we are promising too much.",
      html_body:
        "<p>The draft RFP response is attached. I mainly need a gut check on scope, risk, and where we are promising too much.</p>",
      attachments: %{
        "1" => %{
          "filename" => "rfp-response-draft.docx",
          "content_type" =>
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
          "size" => 98_440,
          "content_id" => "rfp-response@enterprise.com"
        }
      },
      category: "stack",
      stack_at: hours_ago.(16),
      stack_reason: "Needs a long-form response",
      status: "received",
      priority: "high",
      flagged: true,
      read: false,
      inserted_at: days_ago.(2)
    },
    %{
      seed_key: "stack-founder-update",
      mailbox_id: test_mailbox.id,
      from: "founder@startup.io",
      to: "testuser@example.com",
      subject: "Async update before Monday",
      text_body:
        "No immediate action needed. Parking this here until after the retrospective because it will be easier to answer with the final numbers.",
      html_body:
        "<p>No immediate action needed. Parking this here until after the retrospective because it will be easier to answer with the final numbers.</p>",
      category: "stack",
      stack_at: hours_ago.(6),
      stack_reason: "Review after launch retrospective",
      status: "received",
      read: true,
      inserted_at: hours_ago.(20)
    }
  ]

  boomerang_emails = [
    %{
      seed_key: "boomerang-vendor-contract",
      mailbox_id: test_mailbox.id,
      from: "procurement@vendor.com",
      to: "testuser@example.com",
      subject: "Reminder: vendor contract redlines",
      text_body:
        "Pinging this back up in a couple of days once legal has reviewed the draft. No need to answer immediately.",
      html_body:
        "<p>Pinging this back up in a couple of days once legal has reviewed the draft. No need to answer immediately.</p>",
      category: "inbox",
      status: "received",
      read: false,
      priority: "high",
      reply_later_at: days_from_now.(2),
      reply_later_reminder: true,
      inserted_at: hours_ago.(10)
    },
    %{
      seed_key: "boomerang-school-form",
      mailbox_id: test_mailbox.id,
      from: "teacher@school.org",
      to: "testuser@example.com",
      subject: "Field trip form still needed",
      text_body:
        "This got snoozed for later, but the due date has already passed. Good sample for the overdue boomerang state.",
      html_body:
        "<p>This got snoozed for later, but the due date has already passed. Good sample for the <strong>overdue</strong> boomerang state.</p>",
      category: "inbox",
      status: "received",
      read: false,
      reply_later_at: hours_ago.(12),
      reply_later_reminder: true,
      inserted_at: days_ago.(2)
    },
    %{
      seed_key: "boomerang-recruiter-followup",
      mailbox_id: test_mailbox.id,
      from: "recruiter@company.dev",
      to: "testuser@example.com",
      subject: "Checking back on next week",
      text_body:
        "You asked to see this again later today after calendar cleanup. Following up here.",
      html_body:
        "<p>You asked to see this again later today after calendar cleanup. Following up here.</p>",
      category: "inbox",
      status: "received",
      read: true,
      reply_later_at: hours_from_now.(6),
      inserted_at: hours_ago.(3)
    }
  ]

  sent_emails = [
    %{
      seed_key: "thread-launch-blockers-reply",
      mailbox_id: test_mailbox.id,
      from: "testuser@example.com",
      to: "nina@company.com",
      cc: "product@company.com",
      subject: "Re: Q2 launch blockers before Thursday",
      text_body:
        "Sending rough bullets now. I will tighten the rollback owner note tomorrow morning once payments signs off.",
      html_body:
        "<p>Sending rough bullets now. I will tighten the rollback owner note tomorrow morning once payments signs off.</p>",
      status: "sent",
      read: true,
      answered: true,
      in_reply_to: launch_root_id,
      inserted_at: days_ago.(2)
    },
    %{
      seed_key: "sent-budget-proposal",
      mailbox_id: test_mailbox.id,
      from: "testuser@example.com",
      to: "colleague@work.com",
      subject: "Re: Budget Proposal Review",
      text_body:
        "Thanks for the feedback on the budget proposal. I've made the requested changes and attached the updated version.",
      html_body:
        "<p>Thanks for the feedback on the budget proposal. I've made the requested changes and attached the updated version.</p>",
      attachments: %{
        "1" => %{
          "filename" => "budget-proposal-v3.pdf",
          "content_type" => "application/pdf",
          "size" => 154_280,
          "content_id" => "budget-v3@example.com"
        }
      },
      status: "sent",
      read: true,
      inserted_at: days_ago.(8)
    },
    %{
      seed_key: "sent-dinner-plans",
      mailbox_id: test_mailbox.id,
      from: "testuser@example.com",
      to: "friend@gmail.com",
      bcc: "partner@example.com",
      subject: "Dinner plans for Saturday?",
      text_body:
        "Hey! Are we still on for dinner this Saturday? Let me know if you need to reschedule.",
      html_body:
        "<p>Hey! Are we still on for dinner this Saturday? Let me know if you need to reschedule.</p>",
      status: "sent",
      read: true,
      inserted_at: days_ago.(1)
    }
  ]

  draft_emails = [
    %{
      seed_key: "draft-launch-plan",
      mailbox_id: test_mailbox.id,
      from: "testuser@example.com",
      to: "leadership@company.com",
      cc: "ops@company.com",
      bcc: "archive@example.com",
      subject: "Draft: launch plan risks",
      text_body: """
      Draft outline:

      1. Payment fallback owner
      2. Support coverage if migration slips
      3. Customer comms if we need a partial rollback
      """,
      status: "draft",
      priority: "high",
      inserted_at: hours_ago.(2)
    },
    %{
      seed_key: "draft-weekend-note",
      mailbox_id: test_mailbox.id,
      from: "testuser@example.com",
      subject: "Weekend notes",
      text_body: """
      Quick scratch draft:
      - send photos
      - remember parking pass
      - ask about Sunday brunch
      """,
      status: "draft",
      inserted_at: hours_ago.(1)
    }
  ]

  archived_emails = [
    %{
      seed_key: "archive-benefits",
      mailbox_id: test_mailbox.id,
      from: "hr@oldcompany.com",
      to: "testuser@example.com",
      subject: "Final Paycheck and Benefits Information",
      text_body:
        "Please find attached your final paycheck details and information about continuing your benefits.",
      html_body:
        "<p>Please find attached your final paycheck details and information about continuing your benefits.</p>",
      category: "inbox",
      status: "received",
      read: true,
      archived: true,
      inserted_at: days_ago.(120)
    },
    %{
      seed_key: "archive-travel-receipt",
      mailbox_id: test_mailbox.id,
      from: "travel@airline.com",
      to: "testuser@example.com",
      subject: "Trip receipt for Seattle itinerary",
      text_body: "This trip receipt is archived but still useful for expense reports and audits.",
      html_body:
        "<p>This trip receipt is archived but still useful for expense reports and audits.</p>",
      category: "ledger",
      status: "received",
      read: true,
      archived: true,
      is_receipt: true,
      inserted_at: days_ago.(45)
    },
    %{
      seed_key: "archive-newsletter",
      mailbox_id: test_mailbox.id,
      from: "newsletter@designweekly.com",
      to: "testuser@example.com",
      subject: "Design Weekly archive issue",
      text_body:
        "Old newsletter issue kept around for reference while refreshing the design system.",
      html_body:
        "<p>Old newsletter issue kept around for reference while refreshing the design system.</p>",
      category: "feed",
      status: "received",
      read: true,
      archived: true,
      is_newsletter: true,
      inserted_at: days_ago.(20)
    }
  ]

  trash_emails = [
    %{
      seed_key: "trash-rsvp",
      mailbox_id: test_mailbox.id,
      from: "events@conference.io",
      to: "testuser@example.com",
      subject: "Last call for RSVP",
      text_body:
        "This is a plain deleted message so the trash tab has a non-spam, non-draft example.",
      html_body:
        "<p>This is a plain deleted message so the trash tab has a non-spam, non-draft example.</p>",
      category: "inbox",
      status: "received",
      deleted: true,
      read: false,
      inserted_at: days_ago.(5)
    },
    %{
      seed_key: "trash-boomerang-renewal",
      mailbox_id: test_mailbox.id,
      from: "subscriptions@app.com",
      to: "testuser@example.com",
      subject: "Renewal reminder",
      text_body:
        "Deleted boomerang sample. Trash should still show this even though reply_later_at is set.",
      html_body:
        "<p>Deleted boomerang sample. Trash should still show this even though <code>reply_later_at</code> is set.</p>",
      category: "inbox",
      status: "received",
      deleted: true,
      reply_later_at: days_from_now.(1),
      reply_later_reminder: true,
      inserted_at: days_ago.(1)
    }
  ]

  spam_emails = [
    %{
      seed_key: "spam-lottery",
      mailbox_id: test_mailbox.id,
      from: "winner@lottery.fake",
      to: "testuser@example.com",
      subject: "CONGRATULATIONS! You've Won $1,000,000!",
      text_body:
        "You are the lucky winner of our international lottery! Send us your bank details to claim your prize.",
      html_body:
        "<h1>CONGRATULATIONS!</h1><p>You are the lucky winner of our international lottery! Send us your bank details to claim your prize.</p>",
      category: "inbox",
      status: "received",
      read: false,
      spam: true,
      inserted_at: days_ago.(15)
    },
    %{
      seed_key: "spam-phishing",
      mailbox_id: test_mailbox.id,
      from: "urgent@phishing.com",
      to: "testuser@example.com",
      subject: "URGENT: Verify Your Account Now!",
      text_body:
        "Your account will be suspended unless you click this link and verify your information immediately.",
      html_body:
        "<p><strong>URGENT:</strong> Your account will be suspended unless you click this link and verify your information immediately.</p>",
      category: "inbox",
      status: "received",
      read: false,
      spam: true,
      inserted_at: days_ago.(11)
    }
  ]

  seed_groups = [
    {"inbox", inbox_emails},
    {"digest", digest_emails},
    {"ledger", ledger_emails},
    {"stack", stack_emails},
    {"boomerang", boomerang_emails},
    {"sent", sent_emails},
    {"draft", draft_emails},
    {"archived", archived_emails},
    {"trash", trash_emails},
    {"spam", spam_emails}
  ]

  seed_results =
    seed_groups
    |> Enum.flat_map(fn {_group, emails} -> emails end)
    |> Enum.reduce(%{created: 0, existing: 0, repaired: 0}, fn email_attrs, acc ->
      case create_seed_message.(email_attrs) do
        :created -> %{acc | created: acc.created + 1}
        :repaired -> %{acc | repaired: acc.repaired + 1}
        :existing -> %{acc | existing: acc.existing + 1}
      end
    end)

  configured_count =
    seed_groups
    |> Enum.map(fn {_group, emails} -> length(emails) end)
    |> Enum.sum()

  IO.puts(
    "✓ Seed email coverage configured for #{configured_count} scenarios (#{seed_results.created} created, #{seed_results.repaired} repaired, #{seed_results.existing} already present)"
  )

  Enum.each(seed_groups, fn {group, emails} ->
    IO.puts("  - #{length(emails)} #{group} emails")
  end)

  IO.puts("Seeding broader app coverage...")

  local_mail_domain =
    case String.split(test_mailbox.email || "", "@", parts: 2) do
      [_local, domain] when domain != "" -> domain
      _ -> Elektrine.Domains.primary_email_domain()
    end

  local_mail_domain_valid? = String.contains?(local_mail_domain, ".")
  seed_contact_domain = if local_mail_domain_valid?, do: local_mail_domain, else: "example.com"

  ensure_seed_password = fn user, username ->
    case Accounts.admin_reset_password(user, %{password: test_password}) do
      {:ok, updated_user} ->
        IO.puts("✓ Set seed password for '#{username}'")
        updated_user

      {:error, password_error} ->
        IO.puts("✗ Failed to set seed password for '#{username}': #{inspect(password_error)}")
        user
    end
  end

  ensure_seed_user = fn username ->
    case Accounts.get_user_by_username(username) do
      nil ->
        IO.puts("Creating seed user: #{username}")

        case Accounts.create_user(%{
               username: username,
               password: test_password,
               password_confirmation: test_password
             }) do
          {:ok, user} ->
            IO.puts("✓ Seed user created with username: #{username}")
            ensure_seed_password.(user, username)

          {:error, reason} ->
            raise "Failed to create seed user #{username}: #{inspect(reason)}"
        end

      existing_user ->
        IO.puts("✓ Seed user '#{username}' already exists")
        ensure_seed_password.(existing_user, username)
    end
  end

  ensure_user_mailbox = fn user ->
    case ensure_local_mailbox.(user) do
      {:ok, mailbox} ->
        IO.puts("✓ Ensured mailbox for '#{user.username}': #{mailbox.email}")
        mailbox

      {:error, reason} ->
        raise "Failed to ensure mailbox for #{user.username}: #{inspect(reason)}"
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
        profile
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

          {:error, reason} ->
            raise "Failed to create follow #{follower_id}->#{followed_id}: #{inspect(reason)}"
        end

      _follow ->
        :existing
    end
  end

  ensure_remote_actor = fn attrs ->
    case Repo.get_by(Elektrine.ActivityPub.Actor, uri: attrs.uri) do
      nil ->
        %Elektrine.ActivityPub.Actor{}
        |> Elektrine.ActivityPub.Actor.changeset(attrs)
        |> Repo.insert!()

      actor ->
        actor
        |> Elektrine.ActivityPub.Actor.changeset(attrs)
        |> Repo.update!()
    end
  end

  ensure_seed_poll_options = fn poll, option_specs ->
    poll = Repo.preload(poll, :options, force: true)

    if Enum.map(poll.options, & &1.option_text) != Enum.map(option_specs, &elem(&1, 0)) do
      from(option in Social.PollOption, where: option.poll_id == ^poll.id) |> Repo.delete_all()

      option_specs
      |> Enum.with_index()
      |> Enum.each(fn {{option_text, vote_count}, position} ->
        %Social.PollOption{}
        |> Social.PollOption.changeset(%{
          poll_id: poll.id,
          option_text: option_text,
          position: position,
          vote_count: vote_count
        })
        |> Repo.insert!()
      end)
    else
      Enum.each(poll.options, fn option ->
        vote_count = option_specs |> Enum.into(%{}) |> Map.fetch!(option.option_text)

        option
        |> Ecto.Changeset.change(vote_count: vote_count)
        |> Repo.update!()
      end)
    end

    Repo.preload(poll, :options, force: true)
  end

  ensure_federated_poll_post = fn remote_actor, attrs ->
    message_attrs = %{
      activitypub_id: attrs.activitypub_id,
      activitypub_url: attrs.activitypub_url,
      remote_actor_id: remote_actor.id,
      post_type: "poll",
      visibility: "public",
      federated: true,
      content: attrs.content,
      inserted_at: attrs.inserted_at,
      like_count: attrs.like_count,
      reply_count: attrs.reply_count,
      share_count: attrs.share_count,
      media_metadata: %{}
    }

    message =
      case Messaging.get_message_by_activitypub_ref(attrs.activitypub_id) do
        nil ->
          {:ok, created_message} = Messaging.create_federated_message(message_attrs)
          created_message

        existing_message ->
          existing_message
          |> Messaging.Message.federated_changeset(message_attrs)
          |> Repo.update!()
      end

    poll =
      case Repo.preload(message, poll: [options: []]).poll do
        nil ->
          {:ok, created_poll} =
            Social.create_poll(
              message.id,
              attrs.question,
              Enum.map(attrs.options, &elem(&1, 0)),
              closes_at: attrs.closes_at,
              allow_multiple: false,
              hide_totals: false
            )

          created_poll

        existing_poll ->
          existing_poll
          |> Social.Poll.changeset(%{
            question: attrs.question,
            closes_at: attrs.closes_at,
            allow_multiple: false,
            hide_totals: false,
            total_votes: Enum.reduce(attrs.options, 0, fn {_text, votes}, acc -> acc + votes end)
          })
          |> Repo.update!()
      end

    poll =
      poll
      |> Ecto.Changeset.change(
        total_votes: Enum.reduce(attrs.options, 0, fn {_text, votes}, acc -> acc + votes end)
      )
      |> Repo.update!()

    ensure_seed_poll_options.(poll, attrs.options)
    Repo.preload(message, [:remote_actor, poll: [options: []]], force: true)
  end

  ensure_timeline_post = fn user_id, content, opts ->
    post_type = Keyword.get(opts, :post_type, "post")
    reply_to_id = Keyword.get(opts, :reply_to_id)

    existing_post_query =
      from(m in Messaging.Message,
        join: c in Messaging.Conversation,
        on: c.id == m.conversation_id,
        where:
          c.type == "timeline" and
            m.sender_id == ^user_id and
            m.post_type == ^post_type and
            m.content == ^content and
            is_nil(m.deleted_at),
        limit: 1
      )

    existing_post_query =
      if is_nil(reply_to_id) do
        from(m in existing_post_query, where: is_nil(m.reply_to_id))
      else
        from(m in existing_post_query, where: m.reply_to_id == ^reply_to_id)
      end

    existing_post = Repo.one(existing_post_query)

    case existing_post do
      nil ->
        case Social.create_timeline_post(user_id, content, opts) do
          {:ok, post} ->
            post

          {:error, reason} ->
            raise "Failed to create timeline post for #{user_id}: #{inspect(reason)}"
        end

      post ->
        post
    end
  end

  ensure_timeline_draft = fn user_id, content, opts ->
    existing_draft =
      from(m in Messaging.Message,
        join: c in Messaging.Conversation,
        on: c.id == m.conversation_id,
        where:
          c.type == "timeline" and
            m.sender_id == ^user_id and
            m.content == ^content and
            m.is_draft == true and
            is_nil(m.deleted_at),
        limit: 1
      )
      |> Repo.one()

    case existing_draft do
      nil ->
        case Social.Drafts.save_draft(user_id, Keyword.put(opts, :content, content)) do
          {:ok, draft} -> draft
          {:error, reason} -> raise "Failed to create draft for #{user_id}: #{inspect(reason)}"
        end

      draft ->
        draft
    end
  end

  ensure_list = fn user_id, attrs ->
    name = Map.fetch!(attrs, :name)

    case Repo.get_by(Social.List, user_id: user_id, name: name) do
      nil ->
        case Social.create_list(attrs) do
          {:ok, list} -> list
          {:error, reason} -> raise "Failed to create list #{name}: #{inspect(reason)}"
        end

      list ->
        list
    end
  end

  ensure_list_member = fn list_id, user_id ->
    case Repo.get_by(Social.ListMember, list_id: list_id, user_id: user_id) do
      nil ->
        case Social.Lists.add_to_list(list_id, %{user_id: user_id}) do
          {:ok, _member} ->
            :created

          {:error, reason} ->
            raise "Failed to add user #{user_id} to list #{list_id}: #{inspect(reason)}"
        end

      _member ->
        :existing
    end
  end

  ensure_server = fn creator_id, attrs ->
    name = Map.fetch!(attrs, :name)

    existing_server =
      from(s in Messaging.Server,
        where: s.creator_id == ^creator_id and s.name == ^name,
        limit: 1
      )
      |> Repo.one()

    case existing_server do
      nil ->
        case Messaging.create_server(creator_id, attrs) do
          {:ok, server} -> server
          {:error, reason} -> raise "Failed to create server #{name}: #{inspect(reason)}"
        end

      server ->
        server
    end
  end

  ensure_server_membership = fn server_id, user_id ->
    case Messaging.get_server_member(server_id, user_id) do
      nil ->
        case Messaging.join_server(server_id, user_id) do
          {:ok, _member} ->
            :created

          {:error, reason} ->
            raise "Failed to join server #{server_id} for #{user_id}: #{inspect(reason)}"
        end

      _member ->
        :existing
    end
  end

  ensure_server_channel = fn server_id, creator_id, attrs ->
    name = attrs |> Map.get(:name, "general") |> String.downcase()

    case Repo.get_by(Messaging.Conversation, server_id: server_id, type: "channel", name: name) do
      nil ->
        case Messaging.create_server_channel(server_id, creator_id, attrs) do
          {:ok, channel} -> channel
          {:error, reason} -> raise "Failed to create server channel #{name}: #{inspect(reason)}"
        end

      channel ->
        channel
    end
  end

  ensure_group_conversation = fn creator_id, attrs, member_ids ->
    name = attrs |> Map.fetch!(:name) |> String.downcase()

    existing_group =
      from(c in Messaging.Conversation,
        where:
          c.creator_id == ^creator_id and
            c.type == "group" and
            c.name == ^name and
            is_nil(c.server_id),
        limit: 1
      )
      |> Repo.one()

    group =
      case existing_group do
        nil ->
          case Messaging.create_group_conversation(creator_id, attrs, member_ids) do
            {:ok, conversation} ->
              conversation

            {:ok, conversation, _failed_count} ->
              conversation

            {:error, reason} ->
              raise "Failed to create group conversation #{name}: #{inspect(reason)}"
          end

        conversation ->
          conversation
      end

    Enum.each([creator_id | member_ids], fn member_id ->
      case Messaging.Conversations.add_member_to_conversation(group.id, member_id) do
        {:ok, _member} ->
          :ok

        {:error, reason} ->
          raise "Failed to add #{member_id} to group #{group.id}: #{inspect(reason)}"
      end
    end)

    group
  end

  ensure_chat_message = fn conversation_id, sender_id, content, opts ->
    reply_to_id = Keyword.get(opts, :reply_to_id)

    existing_message_query =
      from(m in Messaging.ChatMessage,
        where:
          m.conversation_id == ^conversation_id and
            m.sender_id == ^sender_id and
            m.content == ^content,
        limit: 1
      )

    existing_message_query =
      if is_nil(reply_to_id) do
        from(m in existing_message_query, where: is_nil(m.reply_to_id))
      else
        from(m in existing_message_query, where: m.reply_to_id == ^reply_to_id)
      end

    case Repo.one(existing_message_query) do
      nil ->
        case Messaging.create_text_message(conversation_id, sender_id, content, reply_to_id) do
          {:ok, message} ->
            message

          {:error, reason} ->
            raise "Failed to create chat message in #{conversation_id}: #{inspect(reason)}"
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
        event_attrs =
          attrs
          |> Map.put(:calendar_id, calendar_id)
          |> Map.put(:uid, uid)

        case Calendar.create_event(event_attrs) do
          {:ok, event} -> event
          {:error, reason} -> raise "Failed to create event #{uid}: #{inspect(reason)}"
        end

      event ->
        event
    end
  end

  ensure_contact_group = fn user_id, attrs ->
    name = Map.fetch!(attrs, :name)

    case Repo.get_by(Email.ContactGroup, user_id: user_id, name: name) do
      nil ->
        case Contacts.create_contact_group(attrs) do
          {:ok, group} -> group
          {:error, reason} -> raise "Failed to create contact group #{name}: #{inspect(reason)}"
        end

      group ->
        group
    end
  end

  ensure_contact = fn user_id, attrs ->
    email = Map.fetch!(attrs, :email)

    case Contacts.get_contact_by_email(user_id, email) do
      nil ->
        case Contacts.create_contact(attrs) do
          {:ok, contact} -> contact
          {:error, reason} -> raise "Failed to create contact #{email}: #{inspect(reason)}"
        end

      contact ->
        contact
    end
  end

  ensure_folder = fn user_id, attrs ->
    name = Map.fetch!(attrs, :name)

    case Repo.get_by(Email.Folder, user_id: user_id, name: name) do
      nil ->
        case Email.create_custom_folder(attrs) do
          {:ok, folder} -> folder
          {:error, reason} -> raise "Failed to create folder #{name}: #{inspect(reason)}"
        end

      folder ->
        folder
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

  ensure_template = fn user_id, attrs ->
    name = Map.fetch!(attrs, :name)

    case Email.get_template_by_name(name, user_id) do
      nil ->
        case Email.create_template(attrs) do
          {:ok, template} -> template
          {:error, reason} -> raise "Failed to create template #{name}: #{inspect(reason)}"
        end

      template ->
        template
    end
  end

  ensure_filter = fn user_id, attrs ->
    name = Map.fetch!(attrs, :name)

    case Repo.get_by(Email.Filter, user_id: user_id, name: name) do
      nil ->
        case Email.create_filter(attrs) do
          {:ok, filter} -> filter
          {:error, reason} -> raise "Failed to create filter #{name}: #{inspect(reason)}"
        end

      filter ->
        filter
    end
  end

  ensure_alias = fn alias_email, create_attrs ->
    case Email.get_alias_by_email(alias_email) do
      nil ->
        case Email.create_alias(create_attrs) do
          {:ok, alias_record} -> alias_record
          {:error, reason} -> raise "Failed to create alias #{alias_email}: #{inspect(reason)}"
        end

      alias_record ->
        alias_record
    end
  end

  demo_user_specs = [
    %{
      username: "orbitdev",
      profile: %{
        display_name: "Orbit Dev",
        description: "Shipping product, cleanup, and infrastructure notes in one place.",
        location: "Detroit, MI",
        theme: "blue",
        accent_color: "#38bdf8",
        background_color: "#0f172a",
        icon_color: "#38bdf8",
        font_family: "Consolas"
      },
      links: [
        %{title: "Code Notes", url: "https://example.com/orbitdev", platform: "website"},
        %{title: "GitHub", url: "https://github.com/orbitdev", platform: "github"}
      ]
    },
    %{
      username: "mapsmith",
      profile: %{
        display_name: "Map Smith",
        description: "Calendar-heavy operator keeping launches, travel, and errands in sync.",
        location: "Ann Arbor, MI",
        theme: "green",
        accent_color: "#34d399",
        background_color: "#052e16",
        icon_color: "#34d399",
        font_family: "Verdana"
      },
      links: [
        %{title: "Field Notes", url: "https://example.com/mapsmith", platform: "blog"},
        %{title: "Contact", url: "mailto:mapsmith@example.com", platform: "email"}
      ]
    },
    %{
      username: "pixelvera",
      profile: %{
        display_name: "Pixel Vera",
        description: "Collecting design references, gallery posts, and mobile layout edge cases.",
        location: "Chicago, IL",
        theme: "pink",
        accent_color: "#f472b6",
        background_color: "#500724",
        icon_color: "#f472b6",
        font_family: "Georgia"
      },
      links: [
        %{title: "Portfolio", url: "https://example.com/pixelvera", platform: "portfolio"},
        %{title: "Design Mail", url: "mailto:pixelvera@example.com", platform: "email"}
      ]
    },
    %{
      username: "opsnova",
      profile: %{
        display_name: "Ops Nova",
        description: "Keeping launch rooms tidy, receipts filed, and follow-up loops short.",
        location: "Cleveland, OH",
        theme: "orange",
        accent_color: "#fb923c",
        background_color: "#431407",
        icon_color: "#fb923c",
        font_family: "Trebuchet MS"
      },
      links: [
        %{title: "Runbook", url: "https://example.com/opsnova", platform: "website"},
        %{title: "GitLab", url: "https://gitlab.com/opsnova", platform: "gitlab"}
      ]
    }
  ]

  demo_users =
    Enum.reduce(demo_user_specs, %{}, fn spec, acc ->
      user = ensure_seed_user.(spec.username)
      mailbox = ensure_user_mailbox.(user)

      Map.put(acc, spec.username, %{
        user: user,
        mailbox: mailbox,
        profile: spec.profile,
        links: spec.links
      })
    end)

  profile_seed_specs =
    [
      %{
        user: test_user,
        profile: %{
          display_name: "Test User",
          description: "Seed account with realistic inbox, social, chat, and planning data.",
          location: "Detroit, MI",
          theme: "blue",
          accent_color: "#60a5fa",
          background_color: "#111827",
          icon_color: "#60a5fa",
          font_family: "Inter"
        },
        links: [
          %{title: "Status Page", url: "https://example.com/testuser", platform: "website"},
          %{
            title: "Inbox Alias",
            url: "mailto:testuser@#{seed_contact_domain}",
            platform: "email"
          }
        ]
      }
    ] ++
      Enum.map(demo_user_specs, fn spec ->
        %{user: demo_users[spec.username].user, profile: spec.profile, links: spec.links}
      end)

  Enum.each(profile_seed_specs, fn %{user: user, profile: profile_attrs, links: links} ->
    profile = ensure_profile.(user, profile_attrs)

    links
    |> Enum.with_index()
    |> Enum.each(fn {link_attrs, position} ->
      ensure_profile_link.(profile, Map.put(link_attrs, :position, position))
    end)
  end)

  orbitdev = demo_users["orbitdev"].user
  mapsmith = demo_users["mapsmith"].user
  pixelvera = demo_users["pixelvera"].user
  opsnova = demo_users["opsnova"].user

  follow_pairs = [
    {test_user.id, orbitdev.id},
    {test_user.id, mapsmith.id},
    {test_user.id, pixelvera.id},
    {test_user.id, opsnova.id},
    {orbitdev.id, test_user.id},
    {mapsmith.id, test_user.id}
  ]

  Enum.each(follow_pairs, fn {follower_id, followed_id} ->
    ensure_follow.(follower_id, followed_id)
  end)

  orbit_public_post =
    ensure_timeline_post.(
      orbitdev.id,
      "Seed refresh check: timelines, chat, and calendars now have believable demo state. #elektrine #buildinpublic",
      visibility: "public"
    )

  _orbit_followers_post =
    ensure_timeline_post.(
      orbitdev.id,
      "Followers note: the dev seed now carries a clean DM thread and a war-room server. #shipping",
      visibility: "followers"
    )

  _map_public_post =
    ensure_timeline_post.(
      mapsmith.id,
      "Blocking out next week's travel and review windows in one calendar keeps the rest of the day calmer. #workflow",
      visibility: "public"
    )

  _map_friends_post =
    ensure_timeline_post.(
      mapsmith.id,
      "Friends-only note: lunch after the launch retro is still on if the calendar holds. #friends",
      visibility: "friends"
    )

  pixel_gallery_post =
    ensure_timeline_post.(
      pixelvera.id,
      "Pinned a fresh moodboard for the mobile email pass so the gallery has a real design sample. #design",
      visibility: "public",
      post_type: "gallery",
      category: "design"
    )

  ops_public_post =
    ensure_timeline_post.(
      opsnova.id,
      "The new server channels are a better home for launch checklists than another wandering thread. #ops",
      visibility: "public"
    )

  _test_public_post =
    ensure_timeline_post.(
      test_user.id,
      "Using the seed accounts as a smoke test: inbox, vault, chat, and lists all have enough state to feel real. #qa",
      visibility: "public"
    )

  seed_remote_actor =
    ensure_remote_actor.(%{
      uri: "https://mastodon.seed.local/users/pollbot",
      username: "pollbot",
      domain: "mastodon.seed.local",
      display_name: "Poll Bot",
      summary: "Development seed bot for federated timeline poll testing.",
      avatar_url: "https://mastodon.seed.local/avatars/pollbot.png",
      inbox_url: "https://mastodon.seed.local/users/pollbot/inbox",
      outbox_url: "https://mastodon.seed.local/users/pollbot/outbox",
      followers_url: "https://mastodon.seed.local/users/pollbot/followers",
      following_url: "https://mastodon.seed.local/users/pollbot/following",
      public_key: "seed-dev-public-key-pollbot",
      actor_type: "Person"
    })

  _seed_remote_poll =
    ensure_federated_poll_post.(seed_remote_actor, %{
      activitypub_id: "https://mastodon.seed.local/users/pollbot/statuses/seed-timeline-poll-1",
      activitypub_url: "https://mastodon.seed.local/@pollbot/seed-timeline-poll-1",
      content: "",
      question: "Timeline test poll: does the vote UI update immediately for you?",
      options: [{"Yep, instant feedback", 5}, {"Not yet", 2}, {"I am testing now", 1}],
      inserted_at: DateTime.add(DateTime.utc_now(), -900, :second) |> DateTime.truncate(:second),
      closes_at:
        DateTime.add(DateTime.utc_now(), 3 * 24 * 60 * 60, :second) |> DateTime.truncate(:second),
      like_count: 3,
      reply_count: 1,
      share_count: 2
    })

  _timeline_draft =
    ensure_timeline_draft.(
      test_user.id,
      "Drafting a longer note about the seed audit once the last mobile pass settles.",
      visibility: "followers",
      title: "Seed Audit Notes"
    )

  launch_watch_list =
    ensure_list.(test_user.id, %{
      user_id: test_user.id,
      name: "Launch Watch",
      description: "Seeded list with the demo accounts that post most of the launch chatter.",
      visibility: "public"
    })

  Enum.each([orbitdev.id, mapsmith.id, pixelvera.id], fn user_id ->
    ensure_list_member.(launch_watch_list.id, user_id)
  end)

  unless Social.Likes.user_liked_post?(test_user.id, pixel_gallery_post.id) do
    case Social.like_post(test_user.id, pixel_gallery_post.id) do
      {:ok, _like} ->
        :ok

      {:error, reason} ->
        raise "Failed to like seed post #{pixel_gallery_post.id}: #{inspect(reason)}"
    end
  end

  unless Social.Bookmarks.post_saved?(test_user.id, ops_public_post.id) do
    case Social.save_post(test_user.id, ops_public_post.id) do
      {:ok, _saved} ->
        :ok

      {:error, reason} ->
        raise "Failed to bookmark seed post #{ops_public_post.id}: #{inspect(reason)}"
    end
  end

  unless Social.Boosts.user_boosted?(test_user.id, orbit_public_post.id) do
    case Social.boost_post(test_user.id, orbit_public_post.id) do
      {:ok, _boost} ->
        :ok

      {:error, reason} ->
        raise "Failed to boost seed post #{orbit_public_post.id}: #{inspect(reason)}"
    end
  end

  dm_with_orbit =
    case Messaging.create_dm_conversation(test_user.id, orbitdev.id) do
      {:ok, conversation} -> conversation
      {:error, reason} -> raise "Failed to create DM conversation: #{inspect(reason)}"
    end

  seed_group =
    ensure_group_conversation.(
      test_user.id,
      %{
        name: "Seed QA Room",
        description: "Small group thread for checking seeded UI states."
      },
      [orbitdev.id, pixelvera.id]
    )

  seed_server =
    ensure_server.(test_user.id, %{
      name: "Elektrine Crew",
      description: "Seeded public server for launch, design, and ops chatter.",
      is_public: true
    })

  Enum.each([orbitdev.id, mapsmith.id, pixelvera.id, opsnova.id], fn user_id ->
    ensure_server_membership.(seed_server.id, user_id)
  end)

  general_channel = ensure_server_channel.(seed_server.id, test_user.id, %{name: "general"})

  product_updates_channel =
    ensure_server_channel.(seed_server.id, test_user.id, %{
      name: "product-updates",
      description: "Shipped work, launch notes, and seed script updates."
    })

  design_review_channel =
    ensure_server_channel.(seed_server.id, test_user.id, %{
      name: "design-review",
      description: "Layout feedback and mobile polish threads."
    })

  ensure_chat_message.(
    dm_with_orbit.id,
    orbitdev.id,
    "Can you sanity-check the broader seed data before lunch?",
    []
  )

  ensure_chat_message.(
    dm_with_orbit.id,
    test_user.id,
    "Yes. Timeline, inbox, and chat all look populated now.",
    []
  )

  ensure_chat_message.(
    seed_group.id,
    test_user.id,
    "Dropping screenshots in here after the next seed run.",
    []
  )

  ensure_chat_message.(
    seed_group.id,
    pixelvera.id,
    "Mobile email is much easier to review once the thread view has real content.",
    []
  )

  ensure_chat_message.(
    general_channel.id,
    test_user.id,
    "Using this server as the seeded home for team chatter.",
    []
  )

  ensure_chat_message.(
    general_channel.id,
    opsnova.id,
    "I left the launch checklist in product-updates.",
    []
  )

  ensure_chat_message.(
    product_updates_channel.id,
    orbitdev.id,
    "Seed coverage now includes contacts, calendars, vault entries, and social lists.",
    []
  )

  ensure_chat_message.(
    design_review_channel.id,
    pixelvera.id,
    "The email show view finally has enough content to break layouts on purpose.",
    []
  )

  work_calendar =
    ensure_calendar.(test_user.id, %{
      user_id: test_user.id,
      name: "Work",
      color: "#3b82f6",
      description: "Launch reviews, stakeholder calls, and design crits.",
      timezone: "America/Detroit",
      order: 1
    })

  personal_calendar =
    ensure_calendar.(test_user.id, %{
      user_id: test_user.id,
      name: "Personal",
      color: "#22c55e",
      description: "Travel, family, and after-hours plans.",
      timezone: "America/Detroit",
      order: 2
    })

  _launch_review_event =
    ensure_event.(work_calendar.id, "seed-launch-review@elektrine.dev", %{
      summary: "Launch review",
      description: "Review blockers, fallback plan, and final comms copy.",
      location: "War Room / Video",
      dtstart: hours_from_now.(18),
      dtend: hours_from_now.(19),
      timezone: "America/Detroit",
      attendees: [
        %{"email" => "orbitdev@#{seed_contact_domain}", "name" => "Orbit Dev"},
        %{"email" => "opsnova@#{seed_contact_domain}", "name" => "Ops Nova"}
      ],
      categories: ["launch", "review"]
    })

  _design_crit_event =
    ensure_event.(work_calendar.id, "seed-design-crit@elektrine.dev", %{
      summary: "Design crit",
      description: "Walk through mobile inbox and email show refinements.",
      location: "Studio B",
      dtstart: days_from_now.(2),
      dtend: DateTime.add(days_from_now.(2), 3_600, :second),
      timezone: "America/Detroit",
      attendees: [
        %{"email" => "pixelvera@#{seed_contact_domain}", "name" => "Pixel Vera"}
      ],
      categories: ["design", "mobile"]
    })

  _retro_event =
    ensure_event.(work_calendar.id, "seed-launch-retro@elektrine.dev", %{
      summary: "Launch retro",
      description: "Capture what worked, what slipped, and what should be automated next.",
      location: "Conference Room 2",
      dtstart: days_from_now.(4),
      dtend: DateTime.add(days_from_now.(4), 5_400, :second),
      timezone: "America/Detroit",
      categories: ["retro"]
    })

  _family_event =
    ensure_event.(personal_calendar.id, "seed-family-dinner@elektrine.dev", %{
      summary: "Family dinner",
      description: "Keep one non-work event in the seed so personal calendar views feel real.",
      location: "Grand Rapids",
      dtstart: days_from_now.(3),
      dtend: DateTime.add(days_from_now.(3), 7_200, :second),
      timezone: "America/Detroit",
      categories: ["family"]
    })

  clients_group =
    ensure_contact_group.(test_user.id, %{
      user_id: test_user.id,
      name: "Clients",
      color: "#0ea5e9"
    })

  friends_group =
    ensure_contact_group.(test_user.id, %{
      user_id: test_user.id,
      name: "Friends",
      color: "#22c55e"
    })

  _nina_contact =
    ensure_contact.(test_user.id, %{
      user_id: test_user.id,
      group_id: clients_group.id,
      name: "Nina Shah",
      email: "nina@company.com",
      organization: "Company Inc",
      notes: "Owns launch reviews and escalation notes.",
      favorite: true
    })

  _john_contact =
    ensure_contact.(test_user.id, %{
      user_id: test_user.id,
      group_id: clients_group.id,
      name: "John Doe",
      email: "john.doe@business.com",
      organization: "Business Co",
      notes: "Project documents and budget approvals."
    })

  _casey_contact =
    ensure_contact.(test_user.id, %{
      user_id: test_user.id,
      group_id: friends_group.id,
      name: "Casey Rivera",
      email: "casey@example.com",
      phone: "+1-313-555-0199",
      notes: "Weekend plans and travel check-ins."
    })

  _orbit_contact =
    ensure_contact.(test_user.id, %{
      user_id: test_user.id,
      group_id: friends_group.id,
      name: "Orbit Dev",
      email: "orbitdev@#{seed_contact_domain}",
      organization: "Elektrine",
      favorite: true
    })

  projects_folder =
    ensure_folder.(test_user.id, %{
      user_id: test_user.id,
      name: "Projects",
      color: "#3b82f6",
      icon: "briefcase"
    })

  travel_folder =
    ensure_folder.(test_user.id, %{
      user_id: test_user.id,
      name: "Travel",
      color: "#10b981",
      icon: "bookmark"
    })

  follow_up_label =
    ensure_label.(test_user.id, %{
      user_id: test_user.id,
      name: "FollowUp",
      color: "#f59e0b"
    })

  travel_label =
    ensure_label.(test_user.id, %{
      user_id: test_user.id,
      name: "Travel",
      color: "#06b6d4"
    })

  _weekly_status_template =
    ensure_template.(test_user.id, %{
      user_id: test_user.id,
      name: "Weekly status",
      subject: "Weekly status update",
      body: "Wins:\n- \n\nRisks:\n- \n\nNext:\n- "
    })

  _quick_intro_template =
    ensure_template.(test_user.id, %{
      user_id: test_user.id,
      name: "Quick intro",
      subject: "Intro",
      body: "Hi,\n\nMaking the introduction below.\n\nBest,\nTest User"
    })

  _cloud_invoice_filter =
    ensure_filter.(test_user.id, %{
      user_id: test_user.id,
      name: "Route cloud invoices",
      priority: 10,
      stop_processing: false,
      conditions: %{
        "match_type" => "all",
        "rules" => [
          %{"field" => "from", "operator" => "contains", "value" => "cloudvendor.com"}
        ]
      },
      actions: %{
        "move_to_ledger" => true,
        "mark_as_read" => true
      }
    })

  _review_filter =
    ensure_filter.(test_user.id, %{
      user_id: test_user.id,
      name: "Flag project reviews",
      priority: 20,
      stop_processing: false,
      conditions: %{
        "match_type" => "any",
        "rules" => [
          %{"field" => "subject", "operator" => "contains", "value" => "review"},
          %{"field" => "subject", "operator" => "contains", "value" => "documents"}
        ]
      },
      actions: %{
        "move_to_folder" => projects_folder.id,
        "add_label" => follow_up_label.id,
        "star" => true
      }
    })

  _seed_alias =
    if local_mail_domain_valid? do
      ensure_alias.("testbriefs@#{local_mail_domain}", %{
        username: "testbriefs",
        domain: local_mail_domain,
        user_id: test_user.id,
        description: "Seed alias for testing alternate mailbox routes"
      })
    end

  contract_review_message =
    Repo.get_by(
      Email.Message,
      mailbox_id: test_mailbox.id,
      message_id: seed_message_id.("inbox-contract-review")
    )

  if contract_review_message do
    :ok = Email.add_label_to_message(contract_review_message.id, follow_up_label.id)

    case Email.move_message_to_folder(contract_review_message.id, projects_folder.id) do
      {:ok, _message} -> :ok
      {:error, reason} -> raise "Failed to move contract review email: #{inspect(reason)}"
    end
  end

  flight_confirmation_message =
    Repo.get_by(
      Email.Message,
      mailbox_id: test_mailbox.id,
      message_id: seed_message_id.("ledger-flight-confirmation")
    )

  if flight_confirmation_message do
    :ok = Email.add_label_to_message(flight_confirmation_message.id, travel_label.id)

    case Email.move_message_to_folder(flight_confirmation_message.id, travel_folder.id) do
      {:ok, _message} -> :ok
      {:error, reason} -> raise "Failed to move travel email: #{inspect(reason)}"
    end
  end

  seed_encrypted_payload = fn ciphertext ->
    %{
      "version" => 1,
      "algorithm" => "AES-GCM",
      "kdf" => "PBKDF2-SHA256",
      "iterations" => 150_000,
      "salt" => Base.encode64("0123456789abcdef"),
      "iv" => Base.encode64("seed-initvec"),
      "ciphertext" => Base.encode64(ciphertext)
    }
  end

  unless PasswordManager.vault_configured?(test_user.id) do
    case PasswordManager.setup_vault(test_user.id, %{
           encrypted_verifier: seed_encrypted_payload.("seed-vault-verifier")
         }) do
      {:ok, _settings} -> :ok
      {:error, reason} -> raise "Failed to set up vault: #{inspect(reason)}"
    end
  end

  Enum.each(
    [
      %{
        title: "Linear",
        login_username: "testuser@#{seed_contact_domain}",
        website: "https://linear.app",
        encrypted_password: seed_encrypted_payload.("linear-password-seed"),
        encrypted_notes: seed_encrypted_payload.("Workspace owner: Orbit Dev")
      },
      %{
        title: "Docker",
        login_username: "deployments@#{seed_contact_domain}",
        website: "https://docker.com",
        encrypted_password: seed_encrypted_payload.("docker-password-seed"),
        encrypted_notes:
          seed_encrypted_payload.("Remember to check container health after deploy")
      }
    ],
    fn entry_attrs ->
      case Repo.get_by(PasswordManager.VaultEntry,
             user_id: test_user.id,
             title: entry_attrs.title
           ) do
        nil ->
          case PasswordManager.create_entry(test_user.id, entry_attrs) do
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

  IO.puts("✓ Seeded broader app coverage")
  IO.puts("  - 4 demo users with profiles and mailboxes")
  IO.puts("  - 7 timeline posts, 1 federated poll, 1 draft, and 1 public list")
  IO.puts("  - 1 DM, 1 group conversation, 1 public server, and 3 server channels")
  IO.puts("  - 2 calendars with 4 events and 4 contacts across 2 groups")
  IO.puts("  - 2 folders, 2 labels, 2 templates, 2 filters, 1 alias, and 2 vault entries")

  IO.puts("Development seeding complete!")
  IO.puts("")
  IO.puts("Available accounts:")

  if admin_user do
    IO.puts("  Admin: #{admin_user.username} (#{admin_mailbox.email})")
  else
    IO.puts("  Admin: [FAILED TO CREATE]")
  end

  IO.puts("  Test User: testuser (#{test_mailbox.email})")

  Enum.each(demo_user_specs, fn %{username: username} ->
    IO.puts("  Demo: #{username} (#{username}@#{local_mail_domain})")
  end)

  IO.puts("")
  IO.puts("Seed password (admin + test + demo): #{admin_password}")
else
  IO.puts("Skipping seeds - not in development environment")
end
