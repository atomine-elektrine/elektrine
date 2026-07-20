defmodule ElektrineWeb.PageLive.Legal do
  use ElektrineWeb, :live_view

  alias Elektrine.EmailAddresses

  on_mount {ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user}

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Legal", documents: documents())}
  end

  defp documents do
    [
      %{
        title: "Terms of Service",
        href: ~p"/terms",
        icon: "hero-document-text",
        description: "The agreement that governs your use of Elektrine."
      },
      %{
        title: "Privacy Policy",
        href: ~p"/privacy",
        icon: "hero-lock-closed",
        description: "What we collect, why we collect it, and how it is protected."
      },
      %{
        title: "Warrant Canary",
        href: ~p"/canary",
        icon: "hero-shield-check",
        description:
          "A regularly updated, signed statement about legal orders we have not received."
      },
      %{
        title: "VPN Policy",
        href: Elektrine.Paths.vpn_policy_path(),
        icon: "hero-globe-alt",
        description: "Acceptable use and logging policy for the VPN service."
      }
    ]
  end

  def render(assigns) do
    ~H"""
    <div>
      <div class="pb-8">
        <.e_nav
          active_tab=""
          class="mb-6"
          current_user={@current_user}
          badge_counts={@e_nav_badge_counts}
        />

        <div>
          <header class="mb-8">
            <h1 class="text-3xl font-semibold tracking-tight">Legal</h1>
          </header>

          <.card id="legal-card" class="panel-card" body_class="p-0">
            <:body>
              <.link
                :for={doc <- @documents}
                href={doc.href}
                class="group flex items-center gap-4 border-b border-base-content/10 px-5 py-5 transition-colors hover:bg-base-content/5 sm:px-7"
              >
                <.icon name={doc.icon} class="h-4 w-4 shrink-0 text-base-content/60" />
                <span class="min-w-0 flex-1">
                  <span class="block text-sm font-semibold">{doc.title}</span>
                  <span class="mt-0.5 block text-sm leading-relaxed text-base-content/70">
                    {doc.description}
                  </span>
                </span>
                <.icon
                  name="hero-chevron-right-mini"
                  class="h-4 w-4 shrink-0 text-base-content/30 transition-colors group-hover:text-base-content/60"
                />
              </.link>

              <section class="border-b border-base-content/10 px-5 py-6 sm:px-7">
                <h2 class="text-base font-semibold">License</h2>

                <p class="mt-3 text-sm leading-relaxed text-base-content/70">
                  Elektrine is free software licensed under the GNU Affero General Public
                  License v3.0. You can audit the exact code we run, or self-host it.
                  <a
                    href="https://github.com/atomine-elektrine/elektrine"
                    target="_blank"
                    rel="noopener noreferrer"
                    class="link link-hover text-primary"
                  >
                    Source code
                  </a>
                </p>
              </section>

              <section class="px-5 py-6 sm:px-7">
                <h2 class="text-base font-semibold">Contact</h2>

                <dl class="mt-4 space-y-2 text-sm">
                  <div class="flex gap-3">
                    <dt class="w-16 shrink-0 text-base-content/50">Legal</dt>
                    <dd>
                      <a href={EmailAddresses.mailto("legal")} class="link link-hover text-primary">
                        {EmailAddresses.local("legal")}
                      </a>
                    </dd>
                  </div>

                  <div class="flex gap-3">
                    <dt class="w-16 shrink-0 text-base-content/50">Privacy</dt>
                    <dd>
                      <a href={EmailAddresses.mailto("privacy")} class="link link-hover text-primary">
                        {EmailAddresses.local("privacy")}
                      </a>
                    </dd>
                  </div>
                </dl>
              </section>
            </:body>
          </.card>
        </div>
      </div>
    </div>
    """
  end
end
