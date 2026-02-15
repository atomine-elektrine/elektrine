defmodule ElektrineWeb.PageLive.VPNPolicy do
  use ElektrineWeb, :live_view

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "VPN Service Policy")}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <div class="container mx-auto px-4 py-8 max-w-4xl">
        <div id="vpn-policy-card" phx-hook="GlassCard" class="card glass-card shadow-xl">
          <div class="card-body">
            <h1 class="card-title text-3xl mb-6">VPN Service Policy</h1>

            <div class="prose prose-lg max-w-none">
              <p class="text-sm text-base-content/70 mb-4">Last Updated: October 29, 2025</p>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">1. About the Service</h2>
                <p>
                  Elektrine VPN is a WireGuard-based virtual private network service that protects your privacy
                  by encrypting your internet traffic. The service is provided free to all Elektrine users.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">2. Usage Limits</h2>
                <p>
                  The following limits apply to free users only. Paid subscribers have unlimited access.
                </p>
                <ul class="list-disc pl-6 space-y-2 mt-4">
                  <li><strong>Bandwidth:</strong> 10 GB per month per server configuration</li>
                  <li><strong>Speed:</strong> 50 Mbps default rate limit</li>
                  <li>
                    <strong>Configurations:</strong>
                    One per server (create multiple on different servers)
                  </li>
                  <li><strong>Server Access:</strong> Depends on your trust level (TL0-TL4)</li>
                </ul>
                <p class="mt-4">
                  When you exceed your quota, your configuration is automatically suspended until the next monthly reset.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">3. Acceptable Use Policy</h2>

                <h3 class="text-xl font-semibold mb-2 mt-4">Permitted Uses</h3>
                <p>You may use the VPN service for legitimate purposes including:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Protecting your privacy and securing your internet connection</li>
                  <li>Encrypting your data on public Wi-Fi networks</li>
                  <li>General web browsing, streaming, and online activities</li>
                  <li>Accessing content and services while traveling</li>
                  <li>
                    Bypassing geographical restrictions on content you legally own or subscribe to
                  </li>
                  <li>Protecting business communications and remote work</li>
                  <li>Secure file downloads and uploads</li>
                </ul>

                <h3 class="text-xl font-semibold mb-2 mt-4">Prohibited Activities</h3>
                <p>
                  The following activities are strictly prohibited and will result in immediate action:
                </p>
                <p class="mt-2 font-semibold">
                  Important: Elektrine VPN is operated from the United States. All activities that are illegal under U.S. federal or state law are strictly prohibited, regardless of the legality in your location.
                </p>

                <p class="mt-4"><strong>Illegal Activities:</strong></p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Any activity that violates U.S. federal or state law, or international law</li>
                  <li>Any activity that violates the laws of your local jurisdiction</li>
                  <li>Accessing, distributing, or storing illegal content</li>
                  <li>Copyright infringement or piracy for commercial purposes</li>
                  <li>Child exploitation material (zero tolerance - reported to authorities)</li>
                  <li>Fraud, identity theft, or financial crimes</li>
                  <li>Purchasing or selling illegal goods or services</li>
                </ul>

                <p class="mt-4"><strong>Network Abuse:</strong></p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Distributed Denial of Service (DDoS) attacks</li>
                  <li>Port scanning, network probing, or vulnerability scanning</li>
                  <li>Attempting to breach or compromise any network, system, or server</li>
                  <li>Packet spoofing or IP address spoofing</li>
                  <li>Operating open proxies, open relays, or Tor exit nodes</li>
                  <li>Running botnets or command and control servers</li>
                </ul>

                <p class="mt-4"><strong>Malicious Activities:</strong></p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Distributing malware, viruses, trojans, or ransomware</li>
                  <li>Hacking or attempting unauthorized access to systems</li>
                  <li>Cryptocurrency mining without explicit permission</li>
                  <li>Hosting or distributing phishing pages</li>
                  <li>Participating in or facilitating cyberattacks</li>
                </ul>

                <p class="mt-4"><strong>Spam and Abuse:</strong></p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Sending spam, unsolicited bulk email, or mass messages</li>
                  <li>Email harvesting or scraping contact information</li>
                  <li>Operating spam websites or services</li>
                  <li>Harassment, stalking, or threatening behavior</li>
                  <li>Doxing or publishing private information without consent</li>
                </ul>

                <p class="mt-4"><strong>Service Abuse:</strong></p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Attempting to bypass bandwidth quotas or rate limits</li>
                  <li>Sharing, selling, or reselling your VPN access credentials</li>
                  <li>Using the service to provide VPN access to third parties</li>
                  <li>Operating multiple accounts to circumvent limits</li>
                  <li>Interfering with other users' ability to use the service</li>
                  <li>Excessive bandwidth usage intended to degrade service quality</li>
                </ul>

                <p class="mt-4"><strong>Enforcement:</strong></p>
                <p>
                  Violations of this policy may result in:
                </p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Immediate suspension of VPN access</li>
                  <li>Termination of your Elektrine account</li>
                  <li>Permanent ban from the service</li>
                  <li>Legal action and cooperation with law enforcement when required</li>
                  <li>Liability for damages caused by your actions</li>
                </ul>
                <p class="mt-4">
                  We reserve the right to investigate suspected violations and take appropriate action at our sole discretion.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">4. Privacy</h2>
                <p>We log minimal data for service operation:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Connection times and bandwidth usage for quota management</li>
                  <li>Server used and connection duration</li>
                </ul>

                <p class="mt-4">We do NOT log:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Your browsing history or websites visited</li>
                  <li>DNS queries or traffic content</li>
                  <li>Your IP address after connection</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">5. Support</h2>
                <p>For VPN issues or questions:</p>
                <ul class="list-disc pl-6 space-y-2 mt-2">
                  <li>
                    Check the <.link href={~p"/faq"} class="link link-primary">FAQ</.link>
                    for common questions
                  </li>
                  <li>
                    Contact us via the
                    <.link href={~p"/contact"} class="link link-primary">contact page</.link>
                  </li>
                  <li>
                    Email
                    <a href="mailto:support@elektrine.com" class="link link-primary">
                      support@elektrine.com
                    </a>
                  </li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">6. Changes</h2>
                <p>
                  We may update this policy at any time. Significant changes will be announced through the platform.
                  This policy is part of our <.link href={~p"/terms"} class="link link-primary">Terms of Service</.link>.
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
