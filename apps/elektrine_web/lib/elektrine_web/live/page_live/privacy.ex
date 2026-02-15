defmodule ElektrineWeb.PageLive.Privacy do
  use ElektrineWeb, :live_view

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Privacy Policy")}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <div class="container mx-auto px-4 py-8 max-w-4xl">
        <div id="privacy-card" phx-hook="GlassCard" class="card glass-card shadow-xl">
          <div class="card-body">
            <h1 class="card-title text-3xl mb-6">Privacy Policy</h1>

            <div class="prose prose-lg max-w-none">
              <p class="text-sm text-base-content/70 mb-4">
                Last Updated: {Date.utc_today() |> Date.to_string()}
              </p>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">1. Information We Collect</h2>

                <h3 class="text-xl font-semibold mb-2 mt-4">Information You Provide</h3>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Account information (username, email address)</li>
                  <li>Profile information (display name, avatar)</li>
                  <li>Messages and content you create</li>
                  <li>Files and attachments you upload</li>
                </ul>

                <h3 class="text-xl font-semibold mb-2 mt-4">Information We Collect Automatically</h3>
                <ul class="list-disc pl-6 space-y-2">
                  <li>IP addresses and browser information</li>
                  <li>Device information and operating system</li>
                  <li>Usage data and interaction patterns</li>
                  <li>Login timestamps and session data</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">2. How We Use Your Information</h2>
                <p>We use collected information to:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Provide and improve our services</li>
                  <li>Send and receive messages on your behalf</li>
                  <li>Authenticate and secure your account</li>
                  <li>Prevent fraud and abuse</li>
                  <li>Communicate service updates</li>
                  <li>Respond to support requests</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">3. Data Storage and Security</h2>
                <p>We implement industry-standard security measures including:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Encryption of data in transit (TLS/SSL)</li>
                  <li>Secure password storage using bcrypt/argon2</li>
                  <li>Regular security audits and updates</li>
                  <li>Limited access to personal data</li>
                  <li>Two-factor authentication support</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">4. Data Sharing</h2>
                <p>We do not sell your personal data. We may share information:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>With your explicit consent</li>
                  <li>To comply with legal obligations</li>
                  <li>To protect rights and safety</li>
                  <li>With service providers under strict agreements</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">5. Your Rights</h2>
                <p>You have the right to:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Access your personal data</li>
                  <li>Correct inaccurate information</li>
                  <li>Delete your account and data</li>
                  <li>Export your data</li>
                  <li>Opt-out of marketing communications</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">6. Cookies and Tracking</h2>
                <p>We use essential cookies for:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Session management</li>
                  <li>Security features</li>
                  <li>User preferences</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">7. Data Retention</h2>
                <p>We retain your data while your account is active. Upon account deletion:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Personal data is deleted within 30 days</li>
                  <li>Backups are purged within 90 days</li>
                  <li>Some data may be retained for legal compliance</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">8. Children's Privacy</h2>
                <p>
                  Our services are not directed to children under 13. We do not knowingly collect personal information from children under 13.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">9. International Data Transfers</h2>
                <p>
                  Your data may be processed in countries other than your own. We ensure appropriate safeguards are in place for such transfers.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">10. Changes to This Policy</h2>
                <p>
                  We may update this policy periodically. We will notify you of significant changes via email or service notification.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">11. Contact Us</h2>
                <p>For privacy-related questions or requests:</p>
                <p class="mt-2">
                  Email:
                  <a href="mailto:privacy@elektrine.com" class="link link-primary">
                    privacy@elektrine.com
                  </a>
                </p>
              </section>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
