defmodule ElektrineWeb.PageLive.Home do
  use ElektrineWeb, :live_view

  require Logger

  alias Elektrine.Platform.Modules

  on_mount({ElektrineWeb.Live.AuthHooks, :maybe_authenticated_user})

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Home",
       sidebar_image: home_random_image(),
       sidebar_buttons: home_button_images()
     ), layout: false}
  end

  def render(assigns) do
    ~H"""
    <script nonce={ElektrineWeb.Plugs.SecurityHeaders.script_nonce()} type="application/ld+json">
      {
        "@context": "https://schema.org",
        "@type": "WebSite",
        "name": "Elektrine",
        "url": "#{Domains.public_base_url()}"
      }
    </script>

    <div class="relative min-h-screen overflow-hidden text-base-content">
      <div
        class="pointer-events-none absolute inset-0"
        style="background: radial-gradient(circle at top, color-mix(in srgb, var(--color-primary) 10%, transparent), transparent 34%), radial-gradient(circle at 82% 18%, color-mix(in srgb, var(--color-secondary) 8%, transparent), transparent 20%);"
      >
      </div>

      <div class="relative mx-auto flex min-h-screen max-w-7xl flex-col px-6 py-6 sm:px-8 lg:px-10">
        <header class="flex items-center justify-between gap-4 py-2">
          <.link navigate={~p"/"} class="inline-flex items-center">
            <img src="/images/logo.svg" alt="Elektrine" class="h-8 w-auto sm:h-9" />
          </.link>
        </header>

        <main class="flex flex-1 items-center py-8 lg:py-10">
          <div class="grid w-full items-start gap-8 lg:grid-cols-[minmax(0,1.1fr)_23rem]">
            <section class="space-y-6">
              <div class="card border border-base-300 bg-base-200/80">
                <div class="card-body gap-6 p-6 sm:p-8 lg:p-10">
                  <div class="space-y-4">
                    <div class="space-y-4">
                      <h1 class="max-w-3xl text-4xl font-semibold tracking-tight text-base-content sm:text-5xl lg:text-[3.75rem] lg:leading-[1.02] text-balance">
                        Own or be owned.
                      </h1>
                      <p class="max-w-2xl text-base leading-7 text-base-content/72 sm:text-lg">
                        Elektrine is a private, modular internet suite for people who want everyday
                        services without ads, tracking, or dependence on closed providers. Use the
                        hosted service, or run your own when you want full independence. Open source,
                        licensed under the AGPLv3.
                      </p>
                    </div>
                  </div>

                  <div class="flex flex-wrap items-center gap-3">
                    <%= if @current_user do %>
                      <.link href={~p"/portal"} class="btn btn-primary btn-lg">
                        {gettext("Portal")}
                      </.link>
                      <%= if Modules.enabled?(:email) do %>
                        <.link href={~p"/email"} class="btn btn-ghost btn-lg">
                          {gettext("Email")}
                        </.link>
                      <% end %>
                      <%= if Modules.enabled?(:chat) do %>
                        <.link href={~p"/chat"} class="btn btn-ghost btn-lg">
                          {gettext("Chat")}
                        </.link>
                      <% end %>
                      <.link href={~p"/account"} class="btn btn-ghost btn-lg">
                        {gettext("Account")}
                      </.link>
                      <.link href={~p"/logout"} method="delete" class="btn btn-error btn-lg">
                        {gettext("Sign out")}
                      </.link>
                    <% else %>
                      <.link href={~p"/register"} class="btn btn-primary btn-lg">
                        {gettext("Sign up")}
                      </.link>
                      <.link href={Elektrine.Paths.login_path()} class="btn btn-ghost btn-lg">
                        {gettext("Sign in")}
                      </.link>
                    <% end %>
                  </div>

                  <div class="flex flex-wrap items-center gap-4 border-t border-base-300/80 pt-5 text-sm text-base-content/60">
                    <.link
                      href={github_repo_url()}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="inline-flex items-center gap-2 hover:text-base-content"
                    >
                      <.icon name="hero-code-bracket-mini" class="h-4 w-4" />
                      <span>GitHub</span>
                    </.link>
                    <.link
                      href={github_releases_url()}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="inline-flex items-center gap-2 hover:text-base-content"
                    >
                      <.icon name="hero-arrow-down-tray-mini" class="h-4 w-4" />
                      <span>Releases</span>
                    </.link>
                    <.link
                      href={github_issues_url()}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="inline-flex items-center gap-2 hover:text-base-content"
                    >
                      <.icon name="hero-exclamation-circle-mini" class="h-4 w-4" />
                      <span>Issues</span>
                    </.link>
                    <.link
                      href={~p"/canary"}
                      class="inline-flex items-center gap-2 hover:text-base-content"
                    >
                      <.icon name="hero-shield-check-mini" class="h-4 w-4" />
                      <span>Canary</span>
                    </.link>
                  </div>
                </div>
              </div>

              <div class="card border border-base-300 bg-base-200/80">
                <div class="card-body gap-6 p-6 sm:p-8">
                  <p class="text-xs uppercase tracking-[0.22em] opacity-60">What you get</p>
                  <%= for group <- feature_groups() do %>
                    <div class="space-y-3">
                      <p class="text-[11px] uppercase tracking-[0.18em] opacity-40">{group.label}</p>
                      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
                        <%= for item <- group.items do %>
                          <div class={[
                            "rounded-lg border border-base-300 bg-base-200/45 px-4 py-3",
                            item[:wide] && "sm:col-span-2 lg:col-span-3"
                          ]}>
                            <div class="text-xs uppercase tracking-[0.18em] opacity-50">
                              {item.tag}
                            </div>
                            <div class="mt-1 text-sm font-medium text-base-content">{item.title}</div>
                            <div class="text-xs text-base-content/60">{item.detail}</div>
                          </div>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

              <div class="card border border-base-300 bg-base-200/80">
                <div class="card-body gap-4 p-6 sm:p-8">
                  <p class="text-xs uppercase tracking-[0.22em] opacity-60">For developers</p>
                  <div class="grid gap-4 sm:grid-cols-3">
                    <div class="rounded-lg border border-base-300 bg-base-200/45 px-4 py-3">
                      <div class="text-xs uppercase tracking-[0.18em] opacity-50">OIDC</div>
                      <div class="mt-1 text-sm font-medium text-base-content">
                        Sign in with your domain
                      </div>
                      <div class="text-xs text-base-content/60">
                        OpenID Connect with discovery, JWKS, and dynamic registration
                      </div>
                    </div>
                    <div class="rounded-lg border border-base-300 bg-base-200/45 px-4 py-3">
                      <div class="text-xs uppercase tracking-[0.18em] opacity-50">Tokens</div>
                      <div class="mt-1 text-sm font-medium text-base-content">
                        Scoped access tokens
                      </div>
                      <div class="text-xs text-base-content/60">
                        Fine-grained tokens with separate read and write access per service
                      </div>
                    </div>
                    <div class="rounded-lg border border-base-300 bg-base-200/45 px-4 py-3">
                      <div class="text-xs uppercase tracking-[0.18em] opacity-50">Automate</div>
                      <div class="mt-1 text-sm font-medium text-base-content">
                        Automate everything
                      </div>
                      <div class="text-xs text-base-content/60">
                        JMAP mail, a data-export API, even static-site deploys
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </section>

            <section class="space-y-4 lg:sticky lg:top-10">
              <%!-- Main image: one at random per refresh, from images/home/. --%>
              <%= if @sidebar_image do %>
                <div
                  id="home-sidebar-image"
                  phx-update="ignore"
                  class="overflow-hidden rounded-xl border border-base-300 bg-base-200/45"
                >
                  <img
                    src={~p"/images/home/#{@sidebar_image}"}
                    alt=""
                    class="aspect-[4/3] w-full object-cover"
                    loading="lazy"
                  />
                </div>
              <% else %>
                <div class="flex aspect-[4/3] items-center justify-center rounded-xl border border-dashed border-base-300 bg-base-200/45 text-sm text-base-content/40">
                  Image
                </div>
              <% end %>

              <%!-- Separate 88x31 button wall, always shown (images/home/buttons/). --%>
              <div class="rounded-xl border border-base-300 bg-base-200/45 p-3">
                <div :if={@sidebar_buttons != []} class="flex flex-wrap justify-center gap-1.5">
                  <img
                    :for={button <- @sidebar_buttons}
                    src={~p"/images/home/buttons/#{button}"}
                    alt=""
                    width="88"
                    height="31"
                    class="h-[31px] w-[88px] shrink-0 [image-rendering:pixelated]"
                    loading="lazy"
                  />
                </div>
                <p :if={@sidebar_buttons == []} class="text-sm text-base-content/40">
                  88×31 buttons
                </p>
              </div>
            </section>
          </div>
        </main>
      </div>
    </div>
    """
  end

  defp feature_groups do
    [
      %{
        label: "Mail",
        items: [
          %{tag: "Aliases", title: "Free aliases", detail: "Up to 15 addresses at no extra cost"},
          %{
            tag: "Catch-all",
            title: "Catch-all & plus tags",
            detail: "anything@your-domain and you+tag@ just work"
          },
          %{
            tag: "Domains",
            title: "Free custom domains",
            detail: "Bring your own domain"
          },
          %{
            tag: "Clients",
            title: "Use any mail app",
            detail: "Works in Thunderbird and any IMAP, POP3, SMTP or JMAP client"
          },
          %{
            tag: "Deliverability",
            title: "Lands in the inbox",
            detail: "DKIM, SPF, and DMARC handled for you"
          },
          %{
            tag: "PGP",
            title: "PGP, built in",
            detail: "OpenPGP with automatic key discovery (WKD)"
          }
        ]
      },
      %{
        label: "Privacy & security",
        items: [
          %{
            tag: "First-party",
            title: "No third parties in the loop",
            detail:
              "No Cloudflare, no Google Analytics, no third-party trackers, fonts, or CDNs. Nothing phones home.",
            wide: true
          },
          %{
            tag: "Email",
            title: "Local email encryption",
            detail: "Keys stay in your browser, so the server only ever stores ciphertext"
          },
          %{
            tag: "Chat",
            title: "End-to-end encrypted chat",
            detail: "Messages are encrypted on your device, so the server only relays ciphertext"
          },
          %{
            tag: "Tor",
            title: "Works over Tor",
            detail: "Sign up and use Elektrine privately"
          },
          %{
            tag: "Passkeys",
            title: "Passwordless sign-in",
            detail:
              "Phishing-resistant WebAuthn across up to 10 devices, with no password to steal"
          },
          %{
            tag: "2FA",
            title: "Two-factor auth",
            detail: "TOTP protection on your account"
          },
          %{
            tag: "Signups",
            title: "No CAPTCHAs",
            detail: "A short background check stops bots, so you never solve puzzles"
          },
          %{
            tag: "Open source",
            title: "Open source (AGPLv3)",
            detail: "Audit it, or self-host the exact code we run"
          }
        ]
      },
      %{
        label: "Social and chat",
        items: [
          %{
            tag: "Fediverse",
            title: "On the fediverse",
            detail: "Follow and be followed across Mastodon, Lemmy, and more"
          },
          %{
            tag: "Bluesky",
            title: "Mirror to Bluesky",
            detail: "Crosspost your public timeline to Bluesky"
          },
          %{
            tag: "Messaging",
            title: "Federated messaging",
            detail: "Message and call across Elektrine servers, not just your own"
          }
        ]
      },
      %{
        label: "Beyond the inbox",
        items: [
          %{
            tag: "Knowledge",
            title: "Your knowledge base",
            detail:
              "Kairo ingests notes and sources into a durable, searchable knowledge graph you own"
          },
          %{
            tag: "Secrets",
            title: "Password & secrets manager",
            detail:
              "Nerve keeps passwords and secrets client-side encrypted, so the server only stores ciphertext"
          },
          %{
            tag: "Web search",
            title: "Private web search",
            detail:
              "Search the open web with Maid, which blends results from several engines and never profiles you"
          },
          %{
            tag: "Calendar",
            title: "Calendar & contacts",
            detail: "Sync everywhere with CalDAV and CardDAV"
          },
          %{
            tag: "Portability",
            title: "No lock-in",
            detail: "Export all your data over an open API, any time"
          }
        ]
      }
    ]
  end

  # Sidebar images live in priv/static/images/home/ (served at /images/home/...).
  # Top-level files are full-size images (one shown at random per page load);
  # 88x31 retro buttons go in the buttons/ subfolder and are all shown together.
  defp home_images_dir, do: Path.join(:code.priv_dir(:elektrine), "static/images/home")

  defp home_random_image do
    case home_sidebar_images() do
      [] -> nil
      images -> Enum.random(images)
    end
  end

  defp home_sidebar_images, do: list_images(home_images_dir())

  defp home_button_images, do: list_images(Path.join(home_images_dir(), "buttons"))

  # Format-agnostic listing: skips dotfiles, subdirectories, and the gzipped /
  # content-hashed copies that `mix phx.digest` produces, so any real image the
  # user drops in is included as-is.
  defp list_images(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(fn name ->
          String.starts_with?(name, ".") or
            String.ends_with?(name, ".gz") or
            Regex.match?(~r/-[a-f0-9]{32}\.[^.]+$/, name) or
            File.dir?(Path.join(dir, name))
        end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp github_repo_url, do: "https://github.com/atomine-elektrine/elektrine"

  defp github_releases_url, do: "https://github.com/atomine-elektrine/elektrine/releases"

  defp github_issues_url, do: "https://github.com/atomine-elektrine/elektrine/issues"

  def load_platform_stats(cache_fetch \\ &Elektrine.AppCache.get_platform_stats/1) do
    case cache_fetch.(fn -> default_platform_stats() end) do
      {:ok, stats} ->
        stats

      stats when is_map(stats) ->
        stats

      {:error, reason} ->
        Logger.warning("Home platform stats cache fetch failed: #{Exception.message(reason)}")
        default_platform_stats()
    end
  end

  defp default_platform_stats do
    %{
      stats: %{users: 0, emails: 0, posts: 0},
      federation: %{remote_actors: 0, instances: 0}
    }
  end
end
