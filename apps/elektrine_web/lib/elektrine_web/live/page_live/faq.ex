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
              <h2 class="text-2xl font-semibold mt-6 mb-4">General</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What is Elektrine?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    It's a platform with email, messaging, a social timeline, and some security tools. Started as a side project, grew from there.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Is it free?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yeah. The main stuff (email, chat, timeline) is free and will stay that way. Some features may require an invite code.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  How do I sign up?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Head to the registration page and create an account. You'll get an @elektrine.com email address automatically.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Account</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Username vs handle - what's the difference?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Your username is permanent - it's what you log in with and it's part of your email address (username@elektrine.com). Your handle is the @name people see on your profile and posts. You can change your handle whenever you want in settings, but the username is locked in.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  How do I set up 2FA?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Go to Account Settings and find Two-Factor Authentication. You'll need an authenticator app like Google Authenticator or Authy. Scan the QR code and you're set.
                  </p>
                  <p class="mt-2">
                    <strong>Important:</strong>
                    Save your backup codes somewhere safe. If you lose your phone and don't have the backup codes, you're locked out. We can't recover accounts that have 2FA enabled without those codes.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  I forgot my password
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Use the "Forgot Password" link on the login page. It'll send a reset link to your recovery email. Make sure you've set one up in Account Settings before this happens - we can't manually reset passwords.
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
                    Account Settings -> Delete Account. It goes through an approval process. Once deleted, everything is gone - emails, messages, posts, all of it.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Email</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What's my email address?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    yourusername@elektrine.com - whatever username you picked when signing up.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can I have multiple email addresses?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes, you can create aliases in Email Settings. These are additional addresses that all go to the same inbox. Useful for signing up for different services or keeping things organized.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What are the categories (Inbox, Digest, Ledger, Stack)?
                </div>
                <div class="collapse-content">
                  <p class="pt-2 mb-3">Emails get sorted automatically when they arrive:</p>
                  <p>
                    <strong>Inbox</strong>
                    - Regular emails, personal stuff, anything that looks like actual correspondence.
                  </p>
                  <p class="mt-2">
                    <strong>Digest</strong>
                    - Newsletters, marketing emails, notifications from services. The stuff you might want to read but isn't urgent.
                  </p>
                  <p class="mt-2">
                    <strong>Ledger</strong>
                    - Receipts, invoices, order confirmations, shipping updates. Financial stuff basically.
                  </p>
                  <p class="mt-2">
                    <strong>Stack</strong>
                    - This one's manual. It's for emails you want to save for later, like a bookmark folder.
                  </p>
                  <p class="mt-3">
                    The sorting isn't perfect but it gets it right most of the time. You can always move things around.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What's Boomerang / Reply Later?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    It's for emails you can't deal with right now. Hit Reply Later, pick a time, and the email disappears. When that time comes, it pops back into your inbox like it just arrived. Good for stuff like "I need to respond to this but not at 11pm."
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  File attachment limits?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    10MB per file, up to 5 files per email. Standard stuff - images, PDFs, documents, that kind of thing.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can I use Outlook/Thunderbird/Apple Mail?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">Not right now. It's web-only for the moment.</p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can I export my emails?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. Go to Email Settings -> Export. You can download everything as MBOX (works with most email clients) or as a ZIP of individual .eml files.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  I deleted an email, can you recover it?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    No. Deleted means deleted. There's no trash folder or 30-day grace period. Be sure before you delete something important.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Chat</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  How does messaging work?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    It's real-time chat. You can message anyone on the platform. Supports text, GIFs, emoji reactions, that sort of thing. Messages are stored on our servers.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Are messages encrypted?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    They're encrypted in transit (TLS) but not end-to-end encrypted. We could technically read them if we wanted to, same as most chat platforms. We don't, but if you need real privacy, use Signal or something similar.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Timeline</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What's the timeline?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    It's a social feed. Post updates, follow people, see what they're up to. Think Twitter but smaller and without the algorithm trying to make you angry.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What's ActivityPub / federation?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    ActivityPub is a protocol that lets different social platforms talk to each other. Elektrine supports it, which means you can follow and interact with people on Mastodon, Pixelfed, and other federated platforms. Your posts can be seen by people who aren't even on Elektrine.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Are my posts public?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    By default, yes. Public posts can be seen by anyone, including people on other federated platforms. You can set your profile to private if you want to approve followers first.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Privacy</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Do you sell my data?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    No. We don't sell data, we don't show ads, we don't do any of that stuff.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can you read my emails?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Technically, yes. Same as Gmail, Outlook, or any email provider that isn't doing end-to-end encryption. Your emails sit on our servers and we have access to them. We don't read them because we have better things to do, but we could if legally required to. That's just how email works unless both sender and receiver are using something like PGP.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Where is my data stored?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">Servers in the United States.</p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What happens if Elektrine shuts down?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    We'd give advance notice and time to export your data. The email export feature exists for exactly this reason. Download your stuff regularly if you're worried about it.
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
