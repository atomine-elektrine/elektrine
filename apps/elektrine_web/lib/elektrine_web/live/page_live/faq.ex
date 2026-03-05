defmodule ElektrineWeb.PageLive.FAQ do
  use ElektrineWeb, :live_view

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "FAQ")}
  end

  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <div class="container mx-auto px-4 py-8 max-w-4xl">
        <div id="faq-card" phx-hook="GlassCard" class="card glass-card shadow-xl">
          <div class="card-body">
            <h1 class="card-title text-3xl mb-6">FAQ</h1>

            <div class="space-y-4" id="faq-items" phx-update="ignore">
              <h2 class="text-2xl font-semibold mt-6 mb-4">Platform</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What is Elektrine today?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Elektrine is a unified communication platform. One account can access Overview, Search, Chat, Timeline, Communities, Gallery, Lists, Friends, Email, Password Manager (Vault), VPN, Contacts, and Calendar.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Do I need separate accounts for different features?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    No. A single account works across the platform.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Is registration open to everyone?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    It depends on server configuration. Some deployments allow open registration, while others require invite codes.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Are all features available for every account?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Not always. Some capabilities vary by trust level, subscription/product status, or instance policy (for example: sending limits and available VPN servers).
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Account and Security</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Username vs handle vs preferred email domain - what is the difference?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    <strong>Username</strong>
                    is your login identity and mailbox base name. <strong>Handle</strong>
                    is your public @name on profiles/posts. <strong>Preferred email domain</strong>
                    controls which domain is used by default when sending mail.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can I change my handle?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. Handles can be changed in account settings, with a 30-day cooldown between changes.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What security options are available?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    You can enable recovery email verification, TOTP two-factor authentication, and passkeys.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  How many passkeys can I add?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Up to 10 passkeys per account.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What are app passwords for?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    App passwords are for IMAP/POP3/SMTP clients and other non-browser integrations. They are especially useful when 2FA is enabled.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  How do I delete my account?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Submit a deletion request in Account Settings. Requests are reviewed, and approved deletions permanently remove account data.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Email</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What email addresses do I get?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Your mailbox works on all local domains: {Enum.map_join(
                      Elektrine.Domains.supported_email_domains(),
                      ", ",
                      fn domain ->
                        "username@" <> domain
                      end
                    )}.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can I create additional addresses (aliases)?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. Regular accounts can create up to 15 aliases. Aliases can deliver locally or forward to another address.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What are Inbox, Digest, Ledger, and Stack?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    These are mailbox categories used to organize incoming mail:
                    <strong>Inbox</strong>
                    for direct correspondence, <strong>Digest</strong>
                    for newsletters/updates, <strong>Ledger</strong>
                    for receipts and transactional records, and <strong>Stack</strong>
                    for manually saved items.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What is Reply Later?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Reply Later temporarily removes an email and returns it to your inbox at a chosen time.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What limits should I know about?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Web compose supports up to 5 attachments per message. Standard per-file limit is 25MB (admin accounts can have higher limits). Total message size is capped at 50MB, and SMTP recipient count is capped at 20 recipients per message.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  How does email rate limiting work?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Sending limits are tiered by trust level and account age. New accounts start with strict warmup limits; higher-trust accounts can send up to 1000 emails/day and up to 200 unique recipients/day.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can I use Outlook, Thunderbird, Apple Mail, or mobile clients?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. IMAP, POP3, SMTP, and JMAP are supported. Auto-configuration is available for common clients.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Do Contacts and Calendar sync with other apps?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. Contacts and Calendar are available in the web app and can sync through CardDAV and CalDAV.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can I export my email?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. Email Settings includes export tools for MBOX and ZIP (.eml bundle) downloads.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Is email end-to-end encrypted by default?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    No. Email is encrypted in transit (TLS) and stored server-side. Optional PGP support is available when sender/recipient keys are configured.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Chat</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What does chat support now?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Chat supports direct messages, group chats, server channels, media attachments, emoji reactions, GIFs, typing indicators, and read state indicators.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Is chat end-to-end encrypted?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    No. Chat traffic uses transport encryption, but messages are not end-to-end encrypted.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can I control who can message me?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. Message and invite flows respect account privacy settings.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Social and Communities</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What is the difference between Timeline, Communities, Gallery, and Lists?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Timeline is for fast social posts. Communities are topic spaces for threaded discussions. Gallery focuses on media posts. Lists let you curate who appears in your feeds.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Does federation still work?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. Elektrine uses ActivityPub, so you can interact with users and communities on other federated platforms.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can I restrict who follows me?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. You can enable manual follower approval in account/profile settings.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">VPN</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  How does the VPN feature work?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Elektrine VPN uses WireGuard. You can create configs, download them, and generate QR codes for mobile setup.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Why do available VPN servers differ between accounts?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Server availability can depend on account trust level, subscription/product access, and current server status.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Developer and Integrations</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Is there an API?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. Personal API tokens support scoped access for account, email, social, chat, contacts, and calendar endpoints.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Are webhooks supported?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. You can configure webhooks for supported events, and payloads are signed for verification.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can I export account data?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. Developer settings include account export tools in addition to mailbox export tools.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Privacy and Support</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Do you sell my data?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    No.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Where is data hosted?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Infrastructure is hosted in the United States.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can staff access stored content?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Account and message data is server-stored. Access is restricted, but may occur for security, abuse handling, support operations, or legal obligations.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  How do I contact support?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Email support@elektrine.com. Security issues can be sent to security@elektrine.com. Privacy requests can be sent to privacy@elektrine.com.
                  </p>
                </div>
              </div>
            </div>

            <div class="alert mt-8">
              <div>
                <p>Still have questions? Email support@elektrine.com</p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
