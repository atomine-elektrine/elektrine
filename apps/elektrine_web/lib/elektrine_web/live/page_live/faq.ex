defmodule ElektrineWeb.PageLive.FAQ do
  use ElektrineWeb, :live_view

  alias Elektrine.EmailAddresses

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "FAQ")}
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="mx-auto max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
        <.z_nav active_tab="" class="mb-6" current_user={@current_user} />

        <div id="faq-card" class="card shadow-xl">
          <div class="card-body">
            <h1 class="card-title text-3xl mb-6">FAQ</h1>

            <div class="space-y-4" id="faq-items">
              <h2 class="text-2xl font-semibold mt-6 mb-4">General</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What is Elektrine?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Elektrine is a modular platform for running internet services from one account.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Are the same features available on every deployment?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    No. Deployments can compile in different modules and apply different local policies.
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
                    No. One account works across the modules enabled on the same deployment.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Can registration be invite-only?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Yes. Registration policy depends on the deployment.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Vision and Federation</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What is the vision for Elektrine?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Elektrine is meant to give operators one modular platform for running multiple internet services, while giving users something that feels native and unified rather than a stack of unrelated products.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What does federation mean in Elektrine?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Federation means an Elektrine deployment can exchange activity with other servers instead of acting as a closed silo. The exact behavior depends on which modules are enabled.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Which federated protocols are supported?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    ActivityPub powers the federated social web surface. Arblarg is the messaging federation protocol between domains. Optional Bluesky integration can connect public social posting to ATProto services.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Modes</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What is Overview?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Overview is the dashboard for your account. It brings together activity from the modules enabled on the deployment.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What is Chat?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Chat is the messaging area for direct conversations and group conversations.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What is Timeline?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Timeline is the social feed for posts and updates.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What are Communities?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Communities are topic-based spaces for longer discussion and shared moderation.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What is Gallery?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Gallery is the media-focused view of the social side of Elektrine.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What are Friends?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Friends is the area for managing person-to-person connections on the platform.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What is Vault?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Vault is the password-manager module. When enabled, it stores encrypted entries tied to your account.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Email and Integrations</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  Which client and integration protocols are supported?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    When the relevant modules are enabled, Elektrine supports IMAP, POP3, SMTP, JMAP, CardDAV, CalDAV, and API tokens for integrations.
                  </p>
                </div>
              </div>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  What email addresses are available?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    If email is enabled, local mailboxes use the domains configured for this deployment: {Enum.map_join(
                      Elektrine.Domains.supported_email_domains(),
                      ", ",
                      fn domain ->
                        "username@" <> domain
                      end
                    )}.
                  </p>
                </div>
              </div>

              <h2 class="text-2xl font-semibold mt-6 mb-4">Support</h2>

              <div class="collapse collapse-arrow bg-base-200">
                <input type="checkbox" class="peer" />
                <div class="collapse-title text-lg font-medium peer-checked:bg-primary peer-checked:text-primary-content">
                  How do I get help?
                </div>
                <div class="collapse-content">
                  <p class="pt-2">
                    Support: {EmailAddresses.local("support")}. Security: {EmailAddresses.local(
                      "security"
                    )}. Privacy: {EmailAddresses.local("privacy")}.
                  </p>
                </div>
              </div>
            </div>

            <div class="alert mt-8">
              <div>
                <p>Still have questions? Email {EmailAddresses.local("support")}</p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
