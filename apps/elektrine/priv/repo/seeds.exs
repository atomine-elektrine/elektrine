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

alias Elektrine.Accounts
alias Elektrine.Email
alias Elektrine.Repo

# Only run in development environment
if Mix.env() == :dev do
  IO.puts("Seeding development data...")

  random_seed_password = fn ->
    :crypto.strong_rand_bytes(18)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 18)
  end

  admin_password = System.get_env("SEED_ADMIN_PASSWORD") || random_seed_password.()
  test_password = System.get_env("SEED_TEST_PASSWORD") || random_seed_password.()

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

            case Accounts.create_user(%{
                   username: "sysadmin",
                   password: admin_password,
                   password_confirmation: admin_password
                 }) do
              {:ok, admin_user} ->
                {:ok, admin_user} = Accounts.update_user_admin_status(admin_user, true)
                IO.puts("✓ Admin user created with username: sysadmin")
                admin_user

              {:error, fallback_errors} ->
                IO.puts("✗ Failed to create fallback admin user: #{inspect(fallback_errors)}")
                # Return nil and handle this case below
                nil
            end
        end

      existing_user ->
        # Ensure existing user is admin
        if not existing_user.is_admin do
          {:ok, admin_user} = Accounts.update_user_admin_status(existing_user, true)
          IO.puts("✓ Made existing user '#{admin_username}' an admin")
          admin_user
        else
          IO.puts("✓ Admin user '#{admin_username}' already exists")
          existing_user
        end
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
        existing_user
    end

  # Helper function to get mailbox by email
  get_mailbox_by_email = fn email ->
    import Ecto.Query

    Email.Mailbox
    |> where(email: ^email)
    |> Repo.one()
  end

  # Create mailboxes for both users if they don't exist
  _admin_mailbox =
    if admin_user do
      admin_email = "#{admin_user.username}@elektrine.com"

      case get_mailbox_by_email.(admin_email) do
        nil ->
          {:ok, mailbox} = Email.create_mailbox(%{email: admin_email, user_id: admin_user.id})
          IO.puts("✓ Created admin mailbox: #{admin_email}")
          mailbox

        existing ->
          IO.puts("✓ Admin mailbox already exists: #{admin_email}")
          existing
      end
    else
      IO.puts("✗ Skipping admin mailbox creation (no admin user)")
      nil
    end

  test_mailbox =
    case get_mailbox_by_email.("testuser@elektrine.com") do
      nil ->
        {:ok, mailbox} =
          Email.create_mailbox(%{email: "testuser@elektrine.com", user_id: test_user.id})

        IO.puts("✓ Created test mailbox: testuser@elektrine.com")
        mailbox

      existing ->
        IO.puts("✓ Test mailbox already exists")
        existing
    end

  # Check if we already have seed emails
  existing_count = Repo.aggregate(Email.Message, :count, :id)

  if existing_count == 0 do
    IO.puts("Creating seed emails...")

    # Helper function to create messages
    create_message = fn attrs ->
      base_attrs = %{
        message_id: "seed-#{System.unique_integer()}@elektrine.com",
        inserted_at: DateTime.add(DateTime.utc_now(), -Enum.random(1..30), :day),
        updated_at: DateTime.add(DateTime.utc_now(), -Enum.random(1..30), :day)
      }

      attrs = Map.merge(base_attrs, attrs)
      changeset = Email.Message.changeset(%Email.Message{}, attrs)
      Repo.insert!(changeset)
    end

    # INBOX EMAILS (Regular important emails)
    inbox_emails = [
      %{
        mailbox_id: test_mailbox.id,
        from: "sarah@company.com",
        to: "testuser@elektrine.com",
        subject: "Q4 Planning Meeting Tomorrow",
        text_body:
          "Hi there,\n\nJust a reminder about our Q4 planning meeting tomorrow at 2 PM. Please bring your project updates.\n\nBest,\nSarah",
        html_body:
          "<p>Hi there,</p><p>Just a reminder about our Q4 planning meeting tomorrow at 2 PM. Please bring your project updates.</p><p>Best,<br>Sarah</p>",
        category: "inbox",
        status: "received",
        read: false
      },
      %{
        mailbox_id: test_mailbox.id,
        from: "mike@client.org",
        to: "testuser@elektrine.com",
        subject: "Project Approval - Next Steps",
        text_body:
          "Great news! The project has been approved. Let's schedule a kickoff meeting next week.",
        html_body:
          "<p>Great news! The project has been approved. Let's schedule a kickoff meeting next week.</p>",
        category: "inbox",
        status: "received",
        read: true
      },
      %{
        mailbox_id: test_mailbox.id,
        from: "security@bank.com",
        to: "testuser@elektrine.com",
        subject: "Your Account Statement is Ready",
        text_body:
          "Your monthly account statement is now available for download in your online banking portal.",
        html_body:
          "<p>Your monthly account statement is now available for download in your online banking portal.</p>",
        category: "inbox",
        status: "received",
        read: false,
        is_receipt: true
      },
      %{
        mailbox_id: test_mailbox.id,
        from: "john.doe@business.com",
        to: "testuser@elektrine.com",
        subject: "Project Documents - Please Review",
        text_body: """
        Hi there,

        Please find the attached documents for your review:

        1. project-proposal.pdf - Detailed project specifications
        2. mockup-design.png - UI/UX design mockup  
        3. budget-breakdown.xlsx - Cost analysis and timeline

        Let me know if you have any questions or need clarification on anything.

        Best regards,
        John Doe
        Senior Project Manager
        """,
        html_body: """
        <p>Hi there,</p>

        <p>Please find the attached documents for your review:</p>

        <ol>
          <li><strong>project-proposal.pdf</strong> - Detailed project specifications</li>
          <li><strong>mockup-design.png</strong> - UI/UX design mockup</li>
          <li><strong>budget-breakdown.xlsx</strong> - Cost analysis and timeline</li>
        </ol>

        <p>Let me know if you have any questions or need clarification on anything.</p>

        <p>Best regards,<br>
        <strong>John Doe</strong><br>
        Senior Project Manager</p>
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
            "size" => 89432,
            "content_id" => "attachment2@business.com"
          },
          "3" => %{
            "filename" => "budget-breakdown.xlsx",
            "content_type" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "size" => 12856,
            "content_id" => "attachment3@business.com"
          }
        },
        has_attachments: true,
        category: "inbox",
        status: "received",
        read: false,
        metadata: %{
          "attachment_count" => 3,
          "total_attachment_size" => 348_048,
          "sender_verified" => true
        }
      }
    ]

    # THE PAPER PILE (Bulk/promotional emails)
    paper_pile_emails = [
      %{
        mailbox_id: test_mailbox.id,
        from: "deals@retailstore.com",
        to: "testuser@elektrine.com",
        subject: "Black Friday Sale - Up to 70% Off Everything!",
        text_body:
          "Don't miss our biggest sale of the year! Shop now and save big on all your favorite items.",
        html_body: """
        <html>
        <body style="margin: 0; padding: 0; background-color: #f4f4f4; font-family: Arial, sans-serif;">
          <table width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color: #f4f4f4; padding: 20px;">
            <tr>
              <td align="center">
                <table width="600" cellpadding="0" cellspacing="0" border="0" style="background-color: #ffffff; border-radius: 8px; overflow: hidden;">
                  <!-- Header Banner -->
                  <tr>
                    <td style="background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); padding: 40px 20px; text-align: center;">
                      <h1 style="color: #ffffff; margin: 0; font-size: 32px; font-weight: bold;">BLACK FRIDAY SALE</h1>
                      <p style="color: #ffffff; margin: 10px 0 0 0; font-size: 18px;">Up to 70% Off Everything!</p>
                    </td>
                  </tr>

                  <!-- Product Showcase -->
                  <tr>
                    <td style="padding: 30px 20px;">
                      <table width="100%" cellpadding="10" cellspacing="0" border="0">
                        <tr>
                          <td width="50%" align="center" style="vertical-align: top;">
                            <div style="background-color: #f8f8f8; padding: 20px; border-radius: 8px; margin-bottom: 10px;">
                              <img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='200' height='200'%3E%3Crect fill='%23667eea' width='200' height='200'/%3E%3Ctext x='50%25' y='50%25' fill='white' font-size='20' text-anchor='middle' dy='.3em'%3EProduct 1%3C/text%3E%3C/svg%3E" width="200" height="200" alt="Product 1" style="display: block; border-radius: 4px;">
                              <h3 style="margin: 15px 0 5px 0; color: #333;">Smart Watch Pro</h3>
                              <p style="color: #666; margin: 0; text-decoration: line-through;">$299.99</p>
                              <p style="color: #667eea; margin: 5px 0; font-size: 24px; font-weight: bold;">$89.99</p>
                              <a href="#" style="display: inline-block; background-color: #667eea; color: white; padding: 10px 20px; text-decoration: none; border-radius: 4px; margin-top: 10px;">Shop Now</a>
                            </div>
                          </td>
                          <td width="50%" align="center" style="vertical-align: top;">
                            <div style="background-color: #f8f8f8; padding: 20px; border-radius: 8px; margin-bottom: 10px;">
                              <img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='200' height='200'%3E%3Crect fill='%23764ba2' width='200' height='200'/%3E%3Ctext x='50%25' y='50%25' fill='white' font-size='20' text-anchor='middle' dy='.3em'%3EProduct 2%3C/text%3E%3C/svg%3E" width="200" height="200" alt="Product 2" style="display: block; border-radius: 4px;">
                              <h3 style="margin: 15px 0 5px 0; color: #333;">Wireless Earbuds</h3>
                              <p style="color: #666; margin: 0; text-decoration: line-through;">$149.99</p>
                              <p style="color: #764ba2; margin: 5px 0; font-size: 24px; font-weight: bold;">$44.99</p>
                              <a href="#" style="display: inline-block; background-color: #764ba2; color: white; padding: 10px 20px; text-decoration: none; border-radius: 4px; margin-top: 10px;">Shop Now</a>
                            </div>
                          </td>
                        </tr>
                      </table>

                      <p style="text-align: center; color: #666; margin: 20px 0; font-size: 14px;">Sale ends Sunday at midnight. Don't miss out!</p>
                    </td>
                  </tr>

                  <!-- Footer -->
                  <tr>
                    <td style="background-color: #f8f8f8; padding: 20px; text-align: center;">
                      <p style="color: #999; font-size: 12px; margin: 0;">RetailStore Inc. | 123 Shopping St, Mall City, MC 12345</p>
                      <p style="color: #999; font-size: 12px; margin: 5px 0 0 0;">
                        <a href="#" style="color: #667eea; text-decoration: none;">Unsubscribe</a> |
                        <a href="#" style="color: #667eea; text-decoration: none;">View in Browser</a>
                      </p>
                    </td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
        </body>
        </html>
        """,
        category: "paper_pile",
        status: "received",
        read: false,
        is_newsletter: true
      },
      %{
        mailbox_id: test_mailbox.id,
        from: "newsletter@techblog.com",
        to: "testuser@elektrine.com",
        subject: "Weekly Tech Digest - AI Breakthroughs & More",
        text_body:
          "This week in tech: New AI models, startup funding rounds, and the latest gadget reviews.",
        html_body: """
        <html>
        <body style="margin: 0; padding: 0; background-color: #1a1a1a; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;">
          <table width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color: #1a1a1a; padding: 20px;">
            <tr>
              <td align="center">
                <table width="600" cellpadding="0" cellspacing="0" border="0" style="background-color: #2a2a2a; border-radius: 12px; overflow: hidden;">
                  <!-- Header -->
                  <tr>
                    <td style="padding: 40px 30px; text-align: center; background: linear-gradient(135deg, #1e3a8a 0%, #3b82f6 100%);">
                      <img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='120' height='40'%3E%3Crect fill='white' width='120' height='40' rx='4'/%3E%3Ctext x='50%25' y='50%25' fill='%231e3a8a' font-size='16' font-weight='bold' text-anchor='middle' dy='.3em'%3ETechBlog%3C/text%3E%3C/svg%3E" width="120" height="40" alt="TechBlog" style="display: block; margin: 0 auto;">
                      <h1 style="color: #ffffff; margin: 20px 0 0 0; font-size: 28px; font-weight: 600;">Weekly Tech Digest</h1>
                      <p style="color: #93c5fd; margin: 5px 0 0 0; font-size: 14px;">Your weekly dose of technology news</p>
                    </td>
                  </tr>

                  <!-- Main Article -->
                  <tr>
                    <td style="padding: 30px;">
                      <img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='540' height='300'%3E%3Cdefs%3E%3ClinearGradient id='g' x1='0%25' y1='0%25' x2='100%25' y2='100%25'%3E%3Cstop offset='0%25' style='stop-color:%2306b6d4'/%3E%3Cstop offset='100%25' style='stop-color:%233b82f6'/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect fill='url(%23g)' width='540' height='300'/%3E%3Ctext x='50%25' y='45%25' fill='white' font-size='24' font-weight='bold' text-anchor='middle'%3EAI Breakthrough:%3C/text%3E%3Ctext x='50%25' y='55%25' fill='white' font-size='20' text-anchor='middle'%3ENext-Gen Language Models%3C/text%3E%3C/svg%3E" width="540" height="300" alt="AI Feature" style="display: block; width: 100%; border-radius: 8px; margin-bottom: 20px;">

                      <h2 style="color: #ffffff; margin: 0 0 10px 0; font-size: 24px;">Revolutionary AI Models Released</h2>
                      <p style="color: #9ca3af; margin: 0 0 15px 0; line-height: 1.6;">Leading AI research labs have unveiled groundbreaking language models that demonstrate unprecedented reasoning capabilities, marking a significant leap forward in artificial intelligence development.</p>
                      <a href="#" style="display: inline-block; color: #3b82f6; text-decoration: none; font-weight: 500;">Read more →</a>
                    </td>
                  </tr>

                  <!-- Article Grid -->
                  <tr>
                    <td style="padding: 0 30px 30px 30px;">
                      <table width="100%" cellpadding="0" cellspacing="0" border="0">
                        <tr>
                          <td width="48%" style="vertical-align: top; padding-right: 10px;">
                            <img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='250' height='140'%3E%3Crect fill='%2310b981' width='250' height='140'/%3E%3Ctext x='50%25' y='50%25' fill='white' font-size='16' text-anchor='middle' dy='.3em'%3EStartup Funding%3C/text%3E%3C/svg%3E" width="250" height="140" alt="Startup News" style="display: block; width: 100%; border-radius: 6px; margin-bottom: 10px;">
                            <h3 style="color: #ffffff; margin: 0 0 5px 0; font-size: 16px;">$500M Series C Round</h3>
                            <p style="color: #6b7280; margin: 0; font-size: 14px; line-height: 1.4;">Tech startup secures major funding for expansion.</p>
                          </td>
                          <td width="4%"></td>
                          <td width="48%" style="vertical-align: top; padding-left: 10px;">
                            <img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='250' height='140'%3E%3Crect fill='%23f59e0b' width='250' height='140'/%3E%3Ctext x='50%25' y='50%25' fill='white' font-size='16' text-anchor='middle' dy='.3em'%3EGadget Review%3C/text%3E%3C/svg%3E" width="250" height="140" alt="Gadget Review" style="display: block; width: 100%; border-radius: 6px; margin-bottom: 10px;">
                            <h3 style="color: #ffffff; margin: 0 0 5px 0; font-size: 16px;">Latest Smartphone Review</h3>
                            <p style="color: #6b7280; margin: 0; font-size: 14px; line-height: 1.4;">In-depth look at the newest flagship device.</p>
                          </td>
                        </tr>
                      </table>
                    </td>
                  </tr>

                  <!-- Footer -->
                  <tr>
                    <td style="background-color: #1a1a1a; padding: 20px 30px; text-align: center;">
                      <p style="color: #6b7280; font-size: 12px; margin: 0;">TechBlog Weekly | Delivered every Monday</p>
                      <p style="color: #6b7280; font-size: 12px; margin: 10px 0 0 0;">
                        <a href="#" style="color: #3b82f6; text-decoration: none;">Unsubscribe</a> |
                        <a href="#" style="color: #3b82f6; text-decoration: none;">Update Preferences</a>
                      </p>
                    </td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
        </body>
        </html>
        """,
        category: "paper_pile",
        status: "received",
        read: true,
        is_newsletter: true
      },
      %{
        mailbox_id: test_mailbox.id,
        from: "promotions@fooddelivery.com",
        to: "testuser@elektrine.com",
        subject: "Free Delivery on Your Next Order!",
        text_body:
          "Use code FREEDEL at checkout for free delivery on orders over $20. Valid until Sunday!",
        html_body: """
        <html>
        <body style="margin: 0; padding: 0; background-color: #fef3c7; font-family: Arial, sans-serif;">
          <table width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color: #fef3c7; padding: 20px;">
            <tr>
              <td align="center">
                <table width="600" cellpadding="0" cellspacing="0" border="0" style="background-color: #ffffff; border-radius: 16px; overflow: hidden; box-shadow: 0 4px 6px rgba(0,0,0,0.1);">
                  <!-- Hero Banner -->
                  <tr>
                    <td style="padding: 0;">
                      <img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='600' height='250'%3E%3Cdefs%3E%3ClinearGradient id='bg' x1='0%25' y1='0%25' x2='100%25' y2='100%25'%3E%3Cstop offset='0%25' style='stop-color:%23f59e0b'/%3E%3Cstop offset='100%25' style='stop-color:%23ef4444'/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect fill='url(%23bg)' width='600' height='250'/%3E%3Ctext x='50%25' y='35%25' fill='white' font-size='48' font-weight='bold' text-anchor='middle'%3EFREE%3C/text%3E%3Ctext x='50%25' y='50%25' fill='white' font-size='36' text-anchor='middle'%3EDELIVERY%3C/text%3E%3Ctext x='50%25' y='70%25' fill='white' font-size='20' text-anchor='middle'%3EOn Orders Over $20%3C/text%3E%3C/svg%3E" width="600" height="250" alt="Free Delivery" style="display: block; width: 100%;">
                    </td>
                  </tr>

                  <!-- Promo Code Section -->
                  <tr>
                    <td style="padding: 40px 30px; text-align: center;">
                      <h2 style="color: #dc2626; margin: 0 0 15px 0; font-size: 28px;">Limited Time Offer!</h2>
                      <p style="color: #4b5563; margin: 0 0 25px 0; font-size: 16px; line-height: 1.6;">Enjoy free delivery on your next order. Use promo code at checkout:</p>

                      <div style="background: linear-gradient(135deg, #fbbf24 0%, #f59e0b 100%); border-radius: 8px; padding: 20px; margin: 0 0 25px 0; display: inline-block;">
                        <p style="color: #78350f; margin: 0 0 5px 0; font-size: 14px; font-weight: 600; letter-spacing: 1px;">PROMO CODE</p>
                        <p style="color: #ffffff; margin: 0; font-size: 36px; font-weight: bold; letter-spacing: 3px; font-family: 'Courier New', monospace;">FREEDEL</p>
                      </div>

                      <p style="color: #6b7280; margin: 0 0 30px 0; font-size: 14px;">Valid until Sunday at midnight</p>

                      <a href="#" style="display: inline-block; background: linear-gradient(135deg, #dc2626 0%, #ef4444 100%); color: white; padding: 16px 48px; text-decoration: none; border-radius: 50px; font-size: 18px; font-weight: bold; box-shadow: 0 4px 6px rgba(220,38,38,0.3);">Order Now</a>
                    </td>
                  </tr>

                  <!-- Featured Items -->
                  <tr>
                    <td style="padding: 0 30px 40px 30px;">
                      <h3 style="color: #1f2937; margin: 0 0 20px 0; font-size: 20px; text-align: center;">Popular Right Now</h3>
                      <table width="100%" cellpadding="10" cellspacing="0" border="0">
                        <tr>
                          <td width="33%" align="center">
                            <img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='150' height='150'%3E%3Ccircle cx='75' cy='75' r='75' fill='%23fef3c7'/%3E%3Ccircle cx='75' cy='75' r='60' fill='%23fbbf24'/%3E%3Ctext x='50%25' y='50%25' fill='white' font-size='16' font-weight='bold' text-anchor='middle' dy='.3em'%3EPizza%3C/text%3E%3C/svg%3E" width="150" height="150" alt="Pizza" style="display: block; border-radius: 50%;">
                            <p style="color: #374151; margin: 10px 0 0 0; font-size: 14px; font-weight: 600;">Pizza</p>
                          </td>
                          <td width="33%" align="center">
                            <img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='150' height='150'%3E%3Ccircle cx='75' cy='75' r='75' fill='%23fee2e2'/%3E%3Ccircle cx='75' cy='75' r='60' fill='%23ef4444'/%3E%3Ctext x='50%25' y='50%25' fill='white' font-size='16' font-weight='bold' text-anchor='middle' dy='.3em'%3EBurgers%3C/text%3E%3C/svg%3E" width="150" height="150" alt="Burgers" style="display: block; border-radius: 50%;">
                            <p style="color: #374151; margin: 10px 0 0 0; font-size: 14px; font-weight: 600;">Burgers</p>
                          </td>
                          <td width="33%" align="center">
                            <img src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='150' height='150'%3E%3Ccircle cx='75' cy='75' r='75' fill='%23dcfce7'/%3E%3Ccircle cx='75' cy='75' r='60' fill='%2310b981'/%3E%3Ctext x='50%25' y='50%25' fill='white' font-size='16' font-weight='bold' text-anchor='middle' dy='.3em'%3ESalads%3C/text%3E%3C/svg%3E" width="150" height="150" alt="Salads" style="display: block; border-radius: 50%;">
                            <p style="color: #374151; margin: 10px 0 0 0; font-size: 14px; font-weight: 600;">Salads</p>
                          </td>
                        </tr>
                      </table>
                    </td>
                  </tr>

                  <!-- Footer -->
                  <tr>
                    <td style="background-color: #f9fafb; padding: 20px 30px; text-align: center; border-top: 1px solid #e5e7eb;">
                      <p style="color: #6b7280; font-size: 12px; margin: 0;">FoodDelivery Inc. | Available 24/7</p>
                      <p style="color: #6b7280; font-size: 12px; margin: 10px 0 0 0;">
                        <a href="#" style="color: #f59e0b; text-decoration: none;">Manage Preferences</a> |
                        <a href="#" style="color: #f59e0b; text-decoration: none;">Unsubscribe</a>
                      </p>
                    </td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
        </body>
        </html>
        """,
        category: "paper_pile",
        status: "received",
        read: false,
        is_newsletter: true
      },
      %{
        mailbox_id: test_mailbox.id,
        from: "updates@socialmedia.com",
        to: "testuser@elektrine.com",
        subject: "You have 5 new notifications",
        text_body:
          "Check out what's happening in your network. 3 likes, 1 comment, and 1 new follower.",
        html_body:
          "<p>Check out what's happening in your network. 3 likes, 1 comment, and 1 new follower.</p>",
        category: "paper_pile",
        status: "received",
        read: false,
        is_notification: true
      }
    ]

    # SENT EMAILS
    sent_emails = [
      %{
        mailbox_id: test_mailbox.id,
        from: "testuser@elektrine.com",
        to: "colleague@work.com",
        subject: "Re: Budget Proposal Review",
        text_body:
          "Thanks for the feedback on the budget proposal. I've made the requested changes and attached the updated version.",
        html_body:
          "<p>Thanks for the feedback on the budget proposal. I've made the requested changes and attached the updated version.</p>",
        category: "sent",
        status: "sent",
        read: true
      },
      %{
        mailbox_id: test_mailbox.id,
        from: "testuser@elektrine.com",
        to: "friend@gmail.com",
        subject: "Dinner plans for Saturday?",
        text_body:
          "Hey! Are we still on for dinner this Saturday? Let me know if you need to reschedule.",
        html_body:
          "<p>Hey! Are we still on for dinner this Saturday? Let me know if you need to reschedule.</p>",
        category: "sent",
        status: "sent",
        read: true
      }
    ]

    # ARCHIVED EMAILS (Old but kept)
    archived_emails = [
      %{
        mailbox_id: test_mailbox.id,
        from: "hr@oldcompany.com",
        to: "testuser@elektrine.com",
        subject: "Final Paycheck and Benefits Information",
        text_body:
          "Please find attached your final paycheck details and information about continuing your benefits.",
        html_body:
          "<p>Please find attached your final paycheck details and information about continuing your benefits.</p>",
        category: "inbox",
        status: "received",
        read: true,
        archived: true
      },
      %{
        mailbox_id: test_mailbox.id,
        from: "travel@airline.com",
        to: "testuser@elektrine.com",
        subject: "Flight Confirmation - NYC to LA",
        text_body: "Your flight is confirmed. Flight AA123 on June 15th, departing 8:00 AM.",
        html_body:
          "<p>Your flight is confirmed. Flight AA123 on June 15th, departing 8:00 AM.</p>",
        category: "inbox",
        status: "received",
        read: true,
        archived: true,
        is_receipt: true
      }
    ]

    # SPAM EMAILS
    spam_emails = [
      %{
        mailbox_id: test_mailbox.id,
        from: "winner@lottery.fake",
        to: "testuser@elektrine.com",
        subject: "CONGRATULATIONS! You've Won $1,000,000!",
        text_body:
          "You are the lucky winner of our international lottery! Send us your bank details to claim your prize.",
        html_body:
          "<h1>CONGRATULATIONS!</h1><p>You are the lucky winner of our international lottery! Send us your bank details to claim your prize.</p>",
        category: "inbox",
        status: "received",
        read: false,
        spam: true
      },
      %{
        mailbox_id: test_mailbox.id,
        from: "urgent@phishing.com",
        to: "testuser@elektrine.com",
        subject: "URGENT: Verify Your Account Now!",
        text_body:
          "Your account will be suspended unless you click this link and verify your information immediately.",
        html_body:
          "<p><strong>URGENT:</strong> Your account will be suspended unless you click this link and verify your information immediately.</p>",
        category: "inbox",
        status: "received",
        read: false,
        spam: true
      }
    ]

    all_emails =
      inbox_emails ++ paper_pile_emails ++ sent_emails ++ archived_emails ++ spam_emails

    Enum.each(all_emails, fn email_attrs ->
      create_message.(email_attrs)
    end)

    IO.puts("✓ Created #{length(all_emails)} seed emails:")
    IO.puts("  - #{length(inbox_emails)} inbox emails")
    IO.puts("  - #{length(paper_pile_emails)} paper pile emails")
    IO.puts("  - #{length(sent_emails)} sent emails")
    IO.puts("  - #{length(archived_emails)} archived emails")
    IO.puts("  - #{length(spam_emails)} spam emails")
  else
    IO.puts("✓ Emails already exist (#{existing_count} messages)")
  end

  IO.puts("Development seeding complete!")
  IO.puts("")
  IO.puts("Available accounts:")

  if admin_user do
    IO.puts("  Admin: #{admin_user.username} (#{admin_user.username}@elektrine.com)")
  else
    IO.puts("  Admin: [FAILED TO CREATE]")
  end

  IO.puts("  Test User: testuser (testuser@elektrine.com)")
  IO.puts("")
  IO.puts("Seed passwords are controlled by SEED_ADMIN_PASSWORD and SEED_TEST_PASSWORD.")
else
  IO.puts("Skipping seeds - not in development environment")
end
