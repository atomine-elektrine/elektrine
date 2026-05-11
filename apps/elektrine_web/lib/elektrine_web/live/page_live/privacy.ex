defmodule ElektrineWeb.PageLive.Privacy do
  use ElektrineWeb, :live_view

  alias Elektrine.EmailAddresses

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Privacy Policy")}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="mx-auto max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
        <.e_nav active_tab="" class="mb-6" current_user={@current_user} />

        <div id="privacy-card" class="card panel-card">
          <div class="card-body">
            <h1 class="card-title text-3xl mb-6">Privacy Policy</h1>

            <div class="prose prose-lg max-w-none">
              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">1. Information We Collect</h2>

                <h3 class="text-xl font-semibold mb-2 mt-4">Account and Profile Data</h3>
                <ul class="list-disc pl-6 space-y-2">
                  <li>
                    Account identifiers such as username, mailbox address, login credentials, and recovery or security settings.
                  </li>
                  <li>
                    Profile information you choose to publish, such as display name, avatar, bio, links, and public posts.
                  </li>
                  <li>
                    Preferences such as locale, notification settings, privacy settings, and enabled product features.
                  </li>
                </ul>

                <h3 class="text-xl font-semibold mb-2 mt-4">Content You Store or Send</h3>
                <ul class="list-disc pl-6 space-y-2">
                  <li>
                    Email messages, drafts, sent-mail copies, folders, labels, contacts, aliases, attachments, and filtering preferences.
                  </li>
                  <li>
                    Social posts, chats, notes, files, vault metadata, and other content you create or upload.
                  </li>
                  <li>
                    Operational metadata needed to provide these services, such as message IDs, timestamps, delivery status, mailbox IDs, thread IDs, flags, and storage usage.
                  </li>
                </ul>

                <h3 class="text-xl font-semibold mb-2 mt-4">
                  Information Collected Automatically
                </h3>
                <ul class="list-disc pl-6 space-y-2">
                  <li>
                    IP addresses, user agents, device/browser information, request timestamps, and session identifiers.
                  </li>
                  <li>
                    Security and abuse-prevention data such as login attempts, rate-limit events, SMTP/IMAP/POP connection events, and spam or malware signals.
                  </li>
                  <li>
                    Service logs and metrics used to operate, debug, secure, and improve Elektrine.
                  </li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">2. Email Privacy and Encryption</h2>
                <p>
                  Email uses open internet protocols. Elektrine can protect local storage, but normal SMTP delivery still exposes some information to mail infrastructure.
                </p>

                <h3 class="text-xl font-semibold mb-2 mt-4">Stored Mail</h3>
                <ul class="list-disc pl-6 space-y-2">
                  <li>
                    By default, message bodies are encrypted at rest for the account using server-side application encryption, while some metadata remains available to the server for mailbox operation.
                  </li>
                  <li>
                    If private mailbox storage is enabled, message subject, body, attachments, sender, recipients, and sent-mail copies are stored in browser-unlocked encrypted payloads. The server stores placeholders for protected fields.
                  </li>
                  <li>
                    Private mailbox storage reduces server-side search. Protected subject, body, sender, and recipient fields are not searchable by the server unless a future encrypted-search feature is explicitly enabled.
                  </li>
                  <li>
                    Private mailbox storage does not encrypt every operational field. The server may still store message IDs, mailbox IDs, timestamps, delivery state, folder/label state, read/unread flags, spam/deleted/archive flags, attachment counts, and similar mailbox-management metadata.
                  </li>
                </ul>

                <h3 class="text-xl font-semibold mb-2 mt-4">Mail Delivery</h3>
                <ul class="list-disc pl-6 space-y-2">
                  <li>
                    When you send or receive ordinary email, SMTP envelope data, routing headers, sender, recipient, subject, timestamps, message IDs, DKIM/SPF/DMARC headers, and server IPs/domains may be visible to Elektrine, receiving providers, sending providers, and intermediate mail systems.
                  </li>
                  <li>
                    Outgoing messages must be processed in plaintext by Elektrine/Haraka long enough to format, sign, scan, route, and deliver them unless you use message-level encryption such as PGP.
                  </li>
                  <li>
                    PGP or similar end-to-end content encryption can protect message contents from mail providers and relays, but it does not hide normal email routing metadata.
                  </li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">3. How We Use Information</h2>
                <p>We use information to:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Provide, operate, and maintain Elektrine services.</li>
                  <li>
                    Send, receive, store, sync, filter, and display email and other user content.
                  </li>
                  <li>
                    Authenticate users, protect accounts, prevent fraud and abuse, rate-limit automated activity, and investigate security issues.
                  </li>
                  <li>
                    Debug failures, measure reliability, maintain backups, and improve product behavior.
                  </li>
                  <li>Respond to support, legal, or safety requests.</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">4. Security Measures</h2>
                <p>We use technical and organizational safeguards, including:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>TLS for supported web, API, and mail protocol connections.</li>
                  <li>Hashed password storage and account security controls.</li>
                  <li>
                    Encryption at rest for supported stored content and optional private mailbox storage for browser-unlocked mail protection.
                  </li>
                  <li>
                    Access controls, rate limits, spam/abuse protections, logging, and operational monitoring.
                  </li>
                </ul>
                <p class="mt-3">
                  No system can guarantee perfect security. You are responsible for protecting your account credentials and any private mailbox passphrase or device used to unlock encrypted mailbox content.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">5. Data Sharing</h2>
                <p>We do not sell your personal data. We may share or disclose information:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>
                    With your direction or consent, such as when you send email to another provider or publish public content.
                  </li>
                  <li>
                    With service providers that help us operate infrastructure, storage, delivery, security, monitoring, or support.
                  </li>
                  <li>
                    To deliver email through the public email ecosystem, including DNS, SMTP, DKIM/SPF/DMARC, spam filtering, recipient providers, and remote mail servers.
                  </li>
                  <li>
                    To comply with applicable law, legal process, or enforceable government requests.
                  </li>
                  <li>
                    To protect Elektrine, our users, or the public from abuse, fraud, security threats, or harm.
                  </li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">6. Cookies and Local Storage</h2>
                <p>We use cookies and browser storage for:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Session management and authentication.</li>
                  <li>Security protections and CSRF prevention.</li>
                  <li>User preferences such as theme, locale, and interface state.</li>
                  <li>
                    Private mailbox unlock state in the current browser tab when you choose to unlock protected mail.
                  </li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">7. Logs and Retention</h2>
                <p>
                  We retain account data and user content while your account is active or as needed to provide the service. Operational logs may include IP addresses, request metadata, mail delivery events, rate-limit events, error messages, and security signals.
                </p>
                <ul class="list-disc pl-6 space-y-2 mt-3">
                  <li>
                    Deleting messages or attachments removes them from the active mailbox storage path, subject to backups and operational retention.
                  </li>
                  <li>
                    Account deletion removes or anonymizes personal data where feasible, subject to backups, legal obligations, fraud prevention, abuse records, and deliverability/security logs.
                  </li>
                  <li>
                    Backups and logs may persist for a limited period after deletion before they expire through normal retention cycles.
                  </li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">8. Your Choices and Rights</h2>
                <p>Depending on your location and account status, you may be able to:</p>
                <ul class="list-disc pl-6 space-y-2">
                  <li>Access, correct, export, or delete your account data.</li>
                  <li>
                    Delete messages, attachments, posts, contacts, aliases, and other stored content.
                  </li>
                  <li>
                    Change privacy settings, notification settings, and mailbox encryption settings.
                  </li>
                  <li>Opt out of optional communications where available.</li>
                </ul>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">9. Children's Privacy</h2>
                <p>
                  Our services are not directed to children under 13. We do not knowingly collect personal information from children under 13.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">10. International Data Transfers</h2>
                <p>
                  Your data may be processed in countries other than your own. Where required, we use safeguards appropriate to the processing and providers involved.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">11. Changes to This Policy</h2>
                <p>
                  We may update this policy periodically. We will notify you of significant changes by email, service notification, or posting an updated policy.
                </p>
              </section>

              <section class="mb-8">
                <h2 class="text-2xl font-semibold mb-4">12. Contact Us</h2>
                <p>For privacy-related questions or requests:</p>
                <p class="mt-2">
                  Email:
                  <a href={EmailAddresses.mailto("privacy")} class="link link-primary">
                    {EmailAddresses.local("privacy")}
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
