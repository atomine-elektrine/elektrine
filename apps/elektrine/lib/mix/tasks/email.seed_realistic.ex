defmodule Mix.Tasks.Email.SeedRealistic do
  @shortdoc "Seeds realistic email messages for local testing"

  use Mix.Task

  alias Elektrine.{Accounts, Email, EmailAddresses, Repo}
  alias Elektrine.Email.Message

  @image_seed_version 3

  @moduledoc """
  Seeds a realistic mailbox for testing email rendering, categories, search, and folders.

  Usage:

      mix email.seed_realistic
      mix email.seed_realistic username

  The task is idempotent per mailbox. Existing seed messages are skipped by
  their stable `message_id` values unless this task's seed data version has
  changed, in which case the seed message is replaced.
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    username = parse_username!(args)
    user = get_user!(username)
    mailbox = ensure_mailbox!(user)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Mix.shell().info("Seeding realistic emails for #{mailbox.email}...")

    results =
      mailbox.email
      |> realistic_emails(EmailAddresses.primary_for_user(user) || mailbox.email, now)
      |> Enum.map(&ensure_seed_email(mailbox.id, &1))

    created = Enum.count(results, &(&1 == :created))
    refreshed = Enum.count(results, &(&1 == :refreshed))
    existing = Enum.count(results, &(&1 == :existing))
    failed = Enum.filter(results, &match?({:error, _}, &1))

    Mix.shell().info(
      "Created #{created} realistic emails; refreshed #{refreshed}; skipped #{existing} existing emails."
    )

    if failed != [] do
      Enum.each(failed, fn {:error, {subject, reason}} ->
        Mix.shell().error("Failed: #{subject} - #{inspect(reason)}")
      end)

      System.halt(1)
    end
  end

  defp parse_username!([]), do: first_username!()

  defp parse_username!([username]), do: username

  defp parse_username!(_args) do
    Mix.shell().error("Usage: mix email.seed_realistic [username]")
    System.halt(1)
  end

  defp first_username! do
    case Repo.all(Accounts.User, limit: 1) do
      [%{username: username} | _] -> username
      [] -> Mix.raise("No users found. Create a user first, then rerun the seed task.")
    end
  end

  defp get_user!(username) do
    Accounts.get_user_by_username(username) ||
      Mix.raise("User #{inspect(username)} not found")
  end

  defp ensure_mailbox!(user) do
    case Email.ensure_user_has_mailbox(user) do
      {:ok, mailbox} -> mailbox
      %{} = mailbox -> mailbox
      {:error, reason} -> Mix.raise("Failed to ensure mailbox: #{inspect(reason)}")
      other -> Mix.raise("Failed to ensure mailbox: #{inspect(other)}")
    end
  end

  defp ensure_seed_email(mailbox_id, attrs) do
    attrs =
      attrs
      |> Map.put(:mailbox_id, mailbox_id)
      |> Map.put(:updated_at, Map.fetch!(attrs, :inserted_at))

    message_id = Map.fetch!(attrs, :message_id)

    case Repo.get_by(Message, mailbox_id: mailbox_id, message_id: message_id) do
      nil ->
        case Email.create_message(attrs) do
          {:ok, message} ->
            Mix.shell().info("Created: #{message.subject}")
            :created

          {:error, reason} ->
            {:error, {Map.get(attrs, :subject, message_id), reason}}
        end

      message ->
        if refresh_seed_email?(message) do
          replace_seed_email(message, attrs)
        else
          :existing
        end
    end
  end

  defp replace_seed_email(message, attrs) do
    with {:ok, _deleted_message} <- Email.delete_message(message),
         {:ok, recreated_message} <- Email.create_message(attrs) do
      Mix.shell().info("Refreshed: #{recreated_message.subject}")
      :refreshed
    else
      {:error, reason} ->
        {:error, {Map.get(attrs, :subject, Map.fetch!(attrs, :message_id)), reason}}
    end
  end

  defp refresh_seed_email?(message) do
    metadata = Map.get(message, :metadata) || %{}

    Map.get(metadata, "seed") == "realistic" and
      seed_version(metadata) < @image_seed_version
  end

  defp seed_version(metadata) do
    case Map.get(metadata, "image_seed_version") do
      version when is_integer(version) -> version
      version when is_binary(version) -> String.to_integer(version)
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp realistic_emails(target_email, sender_email, now) do
    [
      %{
        seed_key: "personal-launch-handoff",
        from: "Maya Patel <maya.patel@northstar.studio>",
        to: target_email,
        cc: "ops@northstar.studio, design@brightline.example",
        subject: "Launch handoff: vendor notes and Thursday blockers",
        text_body: """
        Hey,

        I pulled the vendor notes into the launch doc and left three comments for the checkout copy. The only real blocker is legal approval on the revised refund language.

        Can you look at the risk table before noon tomorrow? If it looks good, I will send the final packet to procurement.

        Thanks,
        Maya
        """,
        html_body: personal_handoff_html(),
        attachments: %{
          "northstar-logo" =>
            inline_svg_attachment(
              "northstar-logo@seed",
              "northstar-logo.svg",
              northstar_logo_svg()
            )
        },
        category: "inbox",
        priority: "high",
        read: false,
        status: "received",
        metadata: %{"seed" => "realistic", "headers" => %{}}
      },
      %{
        seed_key: "reply-later-contractor",
        from: "Elliot Vargas <elliot@vargasbuilds.example>",
        to: target_email,
        subject: "Re: patio electrical estimate",
        text_body: """
        The revised estimate is attached below in plain text so you can review on mobile.

        Permit fee: $185
        Trenching and conduit: $640
        Weatherproof outlets: $220
        Labor: $780

        I can hold the Friday morning slot until tomorrow at 4 PM.
        """,
        html_body: contractor_estimate_html(),
        category: "inbox",
        reply_later_at: DateTime.add(now, 2 * 24 * 60 * 60, :second),
        reply_later_reminder: true,
        read: false,
        status: "received",
        metadata: %{"seed" => "realistic", "headers" => %{}}
      },
      %{
        seed_key: "calendar-design-review",
        from: "Priya Raman <calendar@luma.example>",
        to: target_email,
        subject: "Updated invitation: Product design review",
        text_body: """
        Product design review has been moved to Friday at 10:30 AM.

        Agenda:
        1. New onboarding flow
        2. Billing page empty states
        3. Mobile email rendering bugs

        Join: https://meet.luma.example/design-review
        """,
        html_body: calendar_update_html(),
        category: "inbox",
        is_notification: true,
        read: true,
        status: "received",
        metadata: %{
          "seed" => "realistic",
          "headers" => %{"X-Auto-Response-Suppress" => "All"}
        }
      },
      %{
        seed_key: "stripe-receipt",
        from: "Stripe <receipts@stripe.com>",
        to: target_email,
        subject: "Your receipt from Acme Cloud, Inc. #2481-1942",
        text_body: """
        Receipt from Acme Cloud, Inc.

        Pro workspace subscription
        Amount paid: $49.00
        Paid with Visa ending in 4242
        Receipt number: 2481-1942
        """,
        html_body: stripe_receipt_html(),
        category: "ledger",
        is_receipt: true,
        read: false,
        status: "received",
        metadata: %{"seed" => "realistic", "headers" => %{}}
      },
      %{
        seed_key: "bank-statement",
        from: "Riverside Credit Union <statements@riversidecu.example>",
        to: target_email,
        subject: "Your April statement is ready",
        text_body: """
        Your April statement is ready.

        Ending balance: $8,431.22
        Deposits: $6,250.00
        Withdrawals and purchases: $4,102.48

        The attached statement includes transaction details and regulatory notices.
        """,
        html_body: bank_statement_html(),
        attachments: %{
          "statement-april" => %{
            "filename" => "Riverside-Statement-April.pdf",
            "content_type" => "application/pdf",
            "disposition" => "attachment",
            "encoding" => "base64",
            "data" => Base.encode64("%PDF-1.4\nSeed statement for local testing\n%%EOF")
          }
        },
        category: "ledger",
        is_receipt: true,
        read: true,
        status: "received",
        metadata: %{"seed" => "realistic", "headers" => %{}}
      },
      %{
        seed_key: "shipping-update",
        from: "Track & Ship <updates@trackship.example>",
        to: target_email,
        subject: "Out for delivery: order TS-10492",
        text_body: """
        Your package is out for delivery and should arrive today between 1:15 PM and 4:45 PM.

        Tracking number: 1Z999AA10123456784
        Driver note: Leave behind side gate if no answer.
        """,
        html_body: shipping_update_html(),
        category: "inbox",
        is_notification: true,
        read: false,
        status: "received",
        metadata: %{"seed" => "realistic", "headers" => %{}}
      },
      %{
        seed_key: "github-security",
        from: "GitHub <noreply@github.com>",
        to: target_email,
        subject: "Security alert: new SSH key added to your account",
        text_body: """
        A new SSH key named framework-laptop was added to your account.

        Time: May 3, 2026 7:42 PM UTC
        Location: Austin, Texas, United States

        If this was not you, remove the key and reset your password immediately.
        """,
        html_body: github_security_html(),
        category: "inbox",
        is_notification: true,
        priority: "high",
        read: false,
        status: "received",
        metadata: %{
          "seed" => "realistic",
          "headers" => %{"X-GitHub-Recipient" => target_email}
        }
      },
      %{
        seed_key: "postgres-weekly",
        from: "Postgres Weekly <newsletter@postgresweekly.example>",
        to: target_email,
        subject: "Postgres Weekly: indexes, VACUUM, and logical replication",
        text_body: """
        This week in Postgres:

        - Why partial indexes are still underused
        - Practical VACUUM tuning for write-heavy tables
        - Logical replication failover notes

        Sponsored: observability for database teams.
        """,
        html_body: postgres_weekly_html(),
        category: "feed",
        is_newsletter: true,
        read: false,
        status: "received",
        metadata: %{
          "seed" => "realistic",
          "headers" => %{
            "List-Id" => "Postgres Weekly <postgresweekly.example>",
            "List-Unsubscribe" => "<https://postgresweekly.example/unsubscribe>"
          }
        }
      },
      %{
        seed_key: "indeed-broken-css",
        from: "Indeed <alert@indeed.example>",
        to: target_email,
        subject: "Find immediate job opportunities",
        text_body: indeed_broken_css_text(),
        html_body: nil,
        category: "feed",
        is_newsletter: true,
        read: false,
        status: "received",
        metadata: %{
          "seed" => "realistic",
          "headers" => %{"List-Unsubscribe" => "<https://indeed.example/unsubscribe>"}
        }
      },
      %{
        seed_key: "retail-promo",
        from: "Field Supply <hello@fieldsupply.example>",
        to: target_email,
        subject: "Early access: spring gear is 30% off",
        text_body: """
        Early access starts now.

        Jackets, packs, and trail tools are 30% off through Sunday. Members get free shipping over $50.

        Manage preferences or unsubscribe any time.
        """,
        html_body: retail_promo_html(),
        category: "feed",
        is_newsletter: true,
        read: true,
        status: "received",
        metadata: %{
          "seed" => "realistic",
          "headers" => %{"List-Unsubscribe" => "<https://fieldsupply.example/preferences>"}
        }
      },
      %{
        seed_key: "stack-longform",
        from: "Nadia Brooks <nadia@signal-labs.example>",
        to: target_email,
        subject: "Long read: incident review notes",
        text_body: """
        I wrote up the incident review while it was still fresh. No rush today; this is better as a focused read.

        The short version: the retry worker behaved correctly, but our dashboard grouped two unrelated failure modes together.
        """,
        html_body: incident_review_html(),
        category: "stack",
        stack_at: DateTime.add(now, -3 * 60 * 60, :second),
        stack_reason: "Long-form review to read after standup",
        read: false,
        status: "received",
        metadata: %{"seed" => "realistic", "headers" => %{}}
      },
      %{
        seed_key: "archived-github-thread",
        from: "GitHub <notifications@github.com>",
        to: target_email,
        subject: "[elektrine] PR #482: tighten email iframe rendering",
        text_body: """
        ci-bot commented on pull request #482.

        All checks passed. Coverage changed by +0.3%.
        """,
        html_body: github_pr_html(),
        category: "inbox",
        is_notification: true,
        archived: true,
        read: true,
        status: "received",
        metadata: %{
          "seed" => "realistic",
          "headers" => %{"List-Id" => "elektrine.github.com"}
        }
      },
      %{
        seed_key: "spam-phishing",
        from: "Security Desk <secure@paypa1-alerts.example>",
        to: target_email,
        subject: "Final warning: account access limited",
        text_body: """
        Your account access has been limited. Verify your payment details within 2 hours to avoid permanent suspension.

        https://paypa1-alerts.example/verify
        """,
        html_body: phishing_html(),
        spam: true,
        read: false,
        status: "received",
        metadata: %{"seed" => "realistic", "headers" => %{}}
      },
      %{
        seed_key: "sent-vendor-followup",
        from: sender_email,
        to: "Jordan Lee <jordan@printerworks.example>",
        subject: "Re: proofs for the conference badges",
        text_body: """
        Thanks Jordan,

        The second proof looks good. Please proceed with the matte finish and ship to the Austin office.

        Best,
        #{sender_name(sender_email)}
        """,
        html_body: sent_vendor_html(sender_email),
        category: "inbox",
        read: true,
        status: "sent",
        metadata: %{"seed" => "realistic", "headers" => %{}}
      },
      %{
        seed_key: "draft-client-proposal",
        from: sender_email,
        to: "Rae Chen <rae@atlascoffee.example>",
        subject: "Proposal notes for Atlas Coffee",
        text_body: """
        Hi Rae,

        I started outlining the migration plan below. I still need to confirm the DNS cutover window before sending this.

        Proposed phases:
        1. Audit existing inbox rules
        2. Import historical mail
        3. Run dual delivery for 48 hours
        """,
        html_body: draft_proposal_html(),
        category: "inbox",
        read: true,
        status: "draft",
        metadata: %{"seed" => "realistic", "headers" => %{}}
      }
    ]
    |> Enum.with_index()
    |> Enum.map(fn {attrs, index} ->
      seed_key = Map.fetch!(attrs, :seed_key)
      inserted_at = DateTime.add(now, -(index + 1) * 75 * 60, :second)

      attrs
      |> Map.delete(:seed_key)
      |> put_seed_metadata()
      |> Map.put(:message_id, EmailAddresses.uid("realistic-seed-#{seed_key}"))
      |> Map.put(:inserted_at, inserted_at)
    end)
  end

  defp put_seed_metadata(attrs) do
    Map.update(attrs, :metadata, seed_metadata(), fn metadata ->
      metadata
      |> Map.put("seed", "realistic")
      |> Map.put("image_seed_version", @image_seed_version)
    end)
  end

  defp seed_metadata, do: %{"seed" => "realistic", "image_seed_version" => @image_seed_version}

  defp inline_svg_attachment(content_id, filename, svg) do
    %{
      "filename" => filename,
      "content_type" => "image/svg+xml",
      "content_id" => "<#{content_id}>",
      "disposition" => "inline",
      "encoding" => "base64",
      "data" => Base.encode64(svg)
    }
  end

  defp northstar_logo_svg do
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="104" height="104" viewBox="0 0 104 104">
      <rect width="104" height="104" rx="24" fill="#1248B3"/>
      <path d="M52 16l8.8 26.4H88L66 58.7 74.4 86 52 69.2 29.6 86 38 58.7 16 42.4h27.2L52 16z" fill="#fff"/>
    </svg>
    """
  end

  defp sender_name(email) do
    email
    |> String.split("@", parts: 2)
    |> hd()
    |> String.replace([".", "_", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp shell(title, body) do
    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        body { margin:0; background:#f4f6f8; color:#1f2937; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif; }
        .wrap { max-width:640px; margin:0 auto; padding:28px 16px; }
        .card { background:#ffffff; border:1px solid #e5e7eb; border-radius:14px; overflow:hidden; }
        .header { padding:22px 26px; border-bottom:1px solid #eef0f3; }
        .content { padding:24px 26px; font-size:15px; line-height:1.55; }
        .muted { color:#6b7280; }
        .button { display:inline-block; background:#1248b3; color:#ffffff !important; text-decoration:none; padding:11px 16px; border-radius:8px; font-weight:700; }
        img { display:block; max-width:100%; height:auto; border:0; }
        .brand-logo { width:40px; height:40px; border-radius:10px; }
        .hero-img { width:100%; border-radius:12px; margin:0 0 18px; }
        .logo-img { width:52px; height:52px; border-radius:12px; margin:0 0 14px; }
        table { width:100%; border-collapse:collapse; }
        th, td { padding:10px 0; border-bottom:1px solid #eef0f3; text-align:left; }
        @media (max-width: 520px) { .wrap { padding:0; } .card { border-radius:0; border-left:0; border-right:0; } .content,.header { padding-left:18px; padding-right:18px; } }
      </style>
    </head>
    <body>
      <div class="wrap">
        <div class="card">
          <div class="header">
            <table role="presentation" style="width:100%;border-collapse:collapse">
              <tr>
                <td style="width:52px;padding:0;border:0;vertical-align:middle"><img class="brand-logo" src="https://placehold.co/104x104/1248b3/ffffff.png?text=E" width="40" height="40" alt=""></td>
                <td style="padding:0;border:0;vertical-align:middle"><strong>#{title}</strong></td>
              </tr>
            </table>
          </div>
          <div class="content">#{body}</div>
        </div>
      </div>
    </body>
    </html>
    """
  end

  defp personal_handoff_html do
    shell(
      "Launch handoff",
      """
      <img class="logo-img" src="cid:northstar-logo@seed" width="52" height="52" alt="Northstar Studio logo">
      <p>Hey,</p>
      <p>I pulled the vendor notes into the launch doc and left three comments for the checkout copy. The only real blocker is <strong>legal approval on the revised refund language</strong>.</p>
      <p>Can you look at the risk table before noon tomorrow? If it looks good, I will send the final packet to procurement.</p>
      <p class="muted">Thanks,<br>Maya</p>
      """
    )
  end

  defp contractor_estimate_html do
    shell(
      "Patio electrical estimate",
      """
      <p>The revised estimate is below so you can review on mobile.</p>
      <table>
        <tr><td>Permit fee</td><td style="text-align:right">$185</td></tr>
        <tr><td>Trenching and conduit</td><td style="text-align:right">$640</td></tr>
        <tr><td>Weatherproof outlets</td><td style="text-align:right">$220</td></tr>
        <tr><td>Labor</td><td style="text-align:right">$780</td></tr>
      </table>
      <p>I can hold the Friday morning slot until tomorrow at 4 PM.</p>
      """
    )
  end

  defp calendar_update_html do
    shell(
      "Updated invitation",
      """
      <img class="hero-img" src="https://placehold.co/960x260/e0e7ff/3730a3.png?text=Product+Design+Review" width="960" height="260" alt="Product design review calendar banner">
      <p><strong>Product design review</strong> has moved to Friday at 10:30 AM.</p>
      <ol>
        <li>New onboarding flow</li>
        <li>Billing page empty states</li>
        <li>Mobile email rendering bugs</li>
      </ol>
      <p><a class="button" href="https://meet.luma.example/design-review">Join meeting</a></p>
      """
    )
  end

  defp stripe_receipt_html do
    shell(
      "Receipt from Acme Cloud, Inc.",
      """
      <img class="hero-img" src="https://placehold.co/960x260/f7fafc/635bff.png?text=Acme+Cloud+Receipt" width="960" height="260" alt="Acme Cloud receipt banner">
      <table>
        <tr><td>Pro workspace subscription</td><td style="text-align:right">$49.00</td></tr>
        <tr><td>Tax</td><td style="text-align:right">$0.00</td></tr>
        <tr><th>Total paid</th><th style="text-align:right">$49.00</th></tr>
      </table>
      <p class="muted">Paid with Visa ending in 4242. Receipt number 2481-1942.</p>
      """
    )
  end

  defp bank_statement_html do
    shell(
      "Your April statement is ready",
      """
      <p>Your April statement is ready. The attached PDF includes transaction details and regulatory notices.</p>
      <table>
        <tr><td>Ending balance</td><td style="text-align:right">$8,431.22</td></tr>
        <tr><td>Deposits</td><td style="text-align:right">$6,250.00</td></tr>
        <tr><td>Withdrawals and purchases</td><td style="text-align:right">$4,102.48</td></tr>
      </table>
      """
    )
  end

  defp shipping_update_html do
    shell(
      "Out for delivery",
      """
      <img class="hero-img" src="https://placehold.co/960x260/e0f2fe/075985.png?text=Out+For+Delivery" width="960" height="260" alt="Delivery truck illustration">
      <p>Your package should arrive today between <strong>1:15 PM and 4:45 PM</strong>.</p>
      <p>Tracking number: <code>1Z999AA10123456784</code></p>
      <p><a class="button" href="https://trackship.example/t/1Z999AA10123456784">Track package</a></p>
      """
    )
  end

  defp github_security_html do
    shell(
      "Security alert",
      """
      <img class="hero-img" src="https://placehold.co/960x260/111827/f9fafb.png?text=Security+Alert" width="960" height="260" alt="Security alert banner">
      <p>A new SSH key named <strong>framework-laptop</strong> was added to your account.</p>
      <table>
        <tr><td>Time</td><td>May 3, 2026 7:42 PM UTC</td></tr>
        <tr><td>Location</td><td>Austin, Texas, United States</td></tr>
      </table>
      <p>If this was not you, remove the key and reset your password immediately.</p>
      """
    )
  end

  defp postgres_weekly_html do
    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <style>
        body { margin:0; background:#111827; font-family:Georgia,"Times New Roman",serif; color:#111827; }
        .issue { max-width:680px; margin:0 auto; background:#fffaf0; }
        .mast { background:#336791; color:#ffffff; padding:28px; }
        .article { padding:22px 28px; border-bottom:1px solid #e7dcc5; }
        a { color:#1d4ed8; }
        @media only screen and (max-width:600px) { .article,.mast { padding:18px !important; } }
      </style>
    </head>
    <body>
      <div class="issue">
        <div class="mast"><h1 style="margin:0;font-size:28px">Postgres Weekly</h1><p style="margin:8px 0 0">Indexes, VACUUM, and logical replication</p></div>
        <img src="https://placehold.co/1200x360/336791/ffffff.png?text=Postgres+Weekly" width="1200" height="360" alt="Postgres Weekly feature image" style="display:block;width:100%;max-width:100%;height:auto;border:0">
        <div class="article"><h2>Why partial indexes are still underused</h2><p>A practical guide to keeping hot queries fast without indexing every row.</p></div>
        <div class="article"><h2>VACUUM tuning for write-heavy tables</h2><p>How one team reduced table bloat during peak ingest windows.</p></div>
        <div class="article"><p class="muted">You are receiving this because you subscribed to Postgres Weekly.</p></div>
      </div>
    </body>
    </html>
    """
  end

  defp indeed_broken_css_text do
    """
    700&display=swap');

    /* iOS BLUE LINKS */
    a[x-apple-data-detectors] {
      color: inherit !important;
      font-size: inherit !important;
      font-family: inherit !important;
      font-weight: inherit !important;
      line-height: inherit !important;
    }

    /* Samsung blue Links */
    #MessageViewBody a {
      color: inherit;
      text-decoration: none;
      font-size: inherit;
      font-family: inherit;
      font-weight: inherit;
      line-height: inherit;
    }

    @media all and (max-width: 600px) {
      .outerContainer { width: 100% !important }
      .hide { display: none !important }
      .ph-16 { padding-left: 16px !important; padding-right: 16px !important }
    }

    [style*='Noto Sans'] {
      font-family: 'Indeed Sans', 'Noto Sans', Helvetica, Arial, sans-serif !important;
    }

    Find immediate job opportunities &#8204; &#8204; &#8204;

    Find JobsSign in

    Apply now to companies hiring fast

    We have crunched the data from the past few months to find companies that prioritize speed. From engineering to retail, see our 2026 list of employers with the shortest posting-to-hire timelines.

    Get the list

    Your next opportunity is just a minute away

    Looking for your next job should not mean spending hours on applications.
    """
  end

  defp retail_promo_html do
    shell(
      "Field Supply member preview",
      """
      <div style="background:#163225 url('https://placehold.co/1200x420/163225/ffffff.png?text=Field+Supply+Spring+Gear') center/cover no-repeat;color:#ffffff;padding:24px;border-radius:12px;margin-bottom:18px">
        <p style="text-transform:uppercase;letter-spacing:.08em;margin:0 0 8px">Early access</p>
        <h1 style="margin:0;font-size:34px">Spring gear is 30% off</h1>
      </div>
      <img class="hero-img" src="https://placehold.co/960x420/dde8d5/163225.png?text=Jackets+Packs+Trail+Tools" width="960" height="420" alt="Outdoor gear product lineup">
      <p>Jackets, packs, and trail tools are marked down through Sunday. Members get free shipping over $50.</p>
      <p><a class="button" href="https://fieldsupply.example/spring">Shop the preview</a></p>
      """
    )
  end

  defp incident_review_html do
    shell(
      "Incident review notes",
      """
      <p>I wrote up the incident review while it was still fresh. No rush today; this is better as a focused read.</p>
      <blockquote style="border-left:4px solid #f59e0b;margin:16px 0;padding-left:14px;color:#4b5563">The retry worker behaved correctly, but our dashboard grouped two unrelated failure modes together.</blockquote>
      <p>The full write-up has proposed follow-ups for alert names, runbook links, and backfill limits.</p>
      """
    )
  end

  defp github_pr_html do
    shell(
      "Pull request checks",
      """
      <p><strong>ci-bot</strong> commented on pull request #482.</p>
      <pre style="background:#f6f8fa;padding:12px;border-radius:8px;overflow:auto">All checks passed\nCoverage changed by +0.3%</pre>
      <p><a href="https://github.com/example/elektrine/pull/482">View pull request</a></p>
      """
    )
  end

  defp phishing_html do
    shell(
      "Account access limited",
      """
      <p>Your account access has been limited. Verify your payment details within 2 hours to avoid permanent suspension.</p>
      <p><a class="button" href="https://paypa1-alerts.example/verify">Verify account</a></p>
      <p class="muted">This message intentionally looks suspicious for spam-folder testing.</p>
      """
    )
  end

  defp sent_vendor_html(sender_email) do
    shell(
      "Re: proofs for the conference badges",
      """
      <p>Thanks Jordan,</p>
      <p>The second proof looks good. Please proceed with the matte finish and ship to the Austin office.</p>
      <p>Best,<br>#{sender_name(sender_email)}</p>
      """
    )
  end

  defp draft_proposal_html do
    shell(
      "Proposal notes for Atlas Coffee",
      """
      <p>Hi Rae,</p>
      <p>I started outlining the migration plan below. I still need to confirm the DNS cutover window before sending this.</p>
      <ol>
        <li>Audit existing inbox rules</li>
        <li>Import historical mail</li>
        <li>Run dual delivery for 48 hours</li>
      </ol>
      """
    )
  end
end
