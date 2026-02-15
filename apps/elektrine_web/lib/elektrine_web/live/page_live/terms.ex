defmodule ElektrineWeb.PageLive.Terms do
  use ElektrineWeb, :live_view

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Terms of Service")}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <div class="container mx-auto px-4 py-8 max-w-4xl">
        <div id="terms-card" phx-hook="GlassCard" class="card glass-card shadow-xl">
          <div class="card-body">
            <h1 class="card-title text-3xl mb-6">Terms of Service</h1>

            <div class="prose prose-lg max-w-none">
              <p class="text-sm text-base-content/70 mb-4">
                Effective Date: {Date.utc_today() |> Date.to_string()}
              </p>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">1. Acceptance of Terms</h2>
                <p>
                  By accessing or using Elektrine's services, you agree to be bound by these Terms of Service. If you do not agree to these terms, please do not use our services.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">2. Description of Service</h2>
                <p>Elektrine provides:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Email services through the @elektrine.com and @z.org domains</li>
                  <li>Real-time chat and messaging capabilities</li>
                  <li>Social timeline and discussion features</li>
                  <li>File sharing and collaboration tools</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">3. User Accounts</h2>
                <p>To use our services, you must:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Provide accurate and complete information during registration</li>
                  <li>Maintain the security of your account credentials</li>
                  <li>Be at least 13 years of age</li>
                  <li>Notify us immediately of any unauthorized access</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">4. Acceptable Use</h2>
                <p>You agree not to:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Violate any laws or regulations</li>
                  <li>Send spam or unsolicited messages</li>
                  <li>Distribute malware or harmful code</li>
                  <li>Harass, threaten, or harm other users</li>
                  <li>Attempt to gain unauthorized access to systems</li>
                  <li>Use the service for illegal activities</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">5. Content and Privacy</h2>
                <p>
                  You retain ownership of content you create, but grant us a license to store and transmit it as necessary to provide our services. We respect your privacy as outlined in our Privacy Policy.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">6. Service Availability</h2>
                <p>
                  While we strive for 99.9% uptime, we do not guarantee uninterrupted service. We may perform maintenance or updates that temporarily affect availability.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">7. Termination</h2>
                <p>
                  We reserve the right to suspend or terminate accounts that violate these terms. You may delete your account at any time through your account settings.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">8. Disclaimer of Warranties</h2>
                <p>
                  Services are provided "as is" without warranties of any kind, either express or implied.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">9. Limitation of Liability</h2>
                <p>
                  We shall not be liable for any indirect, incidental, special, or consequential damages arising from your use of our services.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">10. Changes to Terms</h2>
                <p>
                  We may update these terms at any time. Continued use of our services after changes constitutes acceptance of the new terms.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">11. Contact Information</h2>
                <p>For questions about these terms, please contact us at:</p>
                <p class="mt-2">
                  Email:
                  <a href="mailto:legal@elektrine.com" class="link link-primary">
                    legal@elektrine.com
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
