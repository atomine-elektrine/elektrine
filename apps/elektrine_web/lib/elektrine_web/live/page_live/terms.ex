defmodule ElektrineWeb.PageLive.Terms do
  use ElektrineWeb, :live_view

  alias Elektrine.EmailAddresses

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Terms of Service", sections: sections())}
  end

  defp sections do
    domains =
      Enum.map_join(Elektrine.Domains.supported_email_domains(), ", ", &("@" <> &1))

    [
      %{
        title: "Acceptance of Terms",
        paras: [
          "By accessing or using Elektrine's services, you agree to be bound by these Terms of Service. If you do not agree to these terms, please do not use our services."
        ],
        items: []
      },
      %{
        title: "Description of Service",
        paras: ["Elektrine provides:"],
        items: [
          "Email services through local domains (#{domains})",
          "Real-time chat and messaging capabilities",
          "Social timeline and discussion features",
          "File sharing and collaboration tools"
        ]
      },
      %{
        title: "User Accounts",
        paras: ["To use our services, you must:"],
        items: [
          "Provide accurate and complete information during registration",
          "Maintain the security of your account credentials",
          "Be at least 13 years of age",
          "Notify us immediately of any unauthorized access"
        ]
      },
      %{
        title: "Acceptable Use",
        paras: ["You agree not to:"],
        items: [
          "Violate any laws or regulations",
          "Send spam or unsolicited messages",
          "Distribute malware or harmful code",
          "Harass, threaten, or harm other users",
          "Attempt to gain unauthorized access to systems",
          "Use the service for illegal activities"
        ]
      },
      %{
        title: "Content and Privacy",
        paras: [
          "You retain ownership of content you create, but grant us a license to store and transmit it as necessary to provide our services. We respect your privacy as outlined in our Privacy Policy."
        ],
        items: []
      },
      %{
        title: "Service Availability",
        paras: [
          "While we strive for 99.9% uptime, we do not guarantee uninterrupted service. We may perform maintenance or updates that temporarily affect availability."
        ],
        items: []
      },
      %{
        title: "Termination",
        paras: [
          "We reserve the right to suspend or terminate accounts that violate these terms. You may delete your account at any time through your account settings."
        ],
        items: []
      },
      %{
        title: "Disclaimer of Warranties",
        paras: [
          "Services are provided \"as is\" without warranties of any kind, either express or implied."
        ],
        items: []
      },
      %{
        title: "Limitation of Liability",
        paras: [
          "We shall not be liable for any indirect, incidental, special, or consequential damages arising from your use of our services."
        ],
        items: []
      },
      %{
        title: "Changes to Terms",
        paras: [
          "We may update these terms at any time. Continued use of our services after changes constitutes acceptance of the new terms."
        ],
        items: []
      }
    ]
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="mx-auto max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
        <.e_nav active_tab="" class="mb-6" current_user={@current_user} />

        <div>
          <header class="mb-8">
            <h1 class="text-3xl font-semibold tracking-tight">Terms of Service</h1>
          </header>

          <.card id="terms-card" class="panel-card" body_class="p-0">
            <:body>
              <section
                :for={{section, index} <- Enum.with_index(@sections, 1)}
                class="border-b border-base-content/10 px-5 py-6 sm:px-7"
              >
                <h2 class="flex items-baseline gap-3 text-base font-semibold">
                  <span class="font-mono text-xs text-base-content/40">
                    {String.pad_leading(Integer.to_string(index), 2, "0")}
                  </span>
                  {section.title}
                </h2>

                <p
                  :for={para <- section.paras}
                  class="mt-3 text-sm leading-relaxed text-base-content/70"
                >
                  {para}
                </p>

                <ul
                  :if={section.items != []}
                  class="mt-3 list-disc space-y-1.5 pl-5 text-sm leading-relaxed text-base-content/70"
                >
                  <li :for={item <- section.items}>{item}</li>
                </ul>
              </section>

              <section class="px-5 py-6 sm:px-7">
                <h2 class="flex items-baseline gap-3 text-base font-semibold">
                  <span class="font-mono text-xs text-base-content/40">
                    {String.pad_leading(Integer.to_string(length(@sections) + 1), 2, "0")}
                  </span>
                  Contact Information
                </h2>

                <p class="mt-3 text-sm leading-relaxed text-base-content/70">
                  For questions about these terms:
                  <a href={EmailAddresses.mailto("legal")} class="link link-hover text-primary">
                    {EmailAddresses.local("legal")}
                  </a>
                </p>
              </section>
            </:body>
          </.card>
        </div>
      </div>
    </div>
    """
  end
end
